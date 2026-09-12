# 07. ビルド・署名・テスト

## `Package.swift`

```swift
// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
]
let mainActorDefault: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "voinp",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "voinp",         targets: ["voinp"]),
        .executable(name: "voinp-offline", targets: ["voinp-offline"]),
    ],
    targets: [
        // ── ネットワークに依存しない層 ──────────────────────────────
        .target(name: "VoinpCore",   swiftSettings: strict),
        .target(name: "VoinpEngine", dependencies: ["VoinpCore"], swiftSettings: strict),

        // UI の中身。ネットワーク側を一切知らない。
        .target(name: "VoinpUIKit",  dependencies: ["VoinpEngine"], swiftSettings: mainActorDefault),

        // ── ネットワーク層 ─────────────────────────────────────────
        .target(name: "VoinpNet",       dependencies: ["VoinpCore"],             swiftSettings: strict),
        .target(name: "VoinpProviders", dependencies: ["VoinpCore", "VoinpNet"], swiftSettings: strict),

        // ── 合成ルート: 薄い実行ターゲットを 2 つ ────────────────────
        // 各 20 行程度。Dependencies の組み立て方だけが違う。
        .executableTarget(
            name: "voinp",
            dependencies: ["VoinpUIKit", "VoinpProviders", "VoinpNet"],
            swiftSettings: mainActorDefault),

        .executableTarget(
            name: "voinp-offline",
            dependencies: ["VoinpUIKit"],     // ← VoinpNet も VoinpProviders も無い
            swiftSettings: mainActorDefault),

        // ── テスト ────────────────────────────────────────────────
        .target(name: "VoinpTestSupport", dependencies: ["VoinpCore"], swiftSettings: strict),
        .testTarget(name: "VoinpCoreTests",
                    dependencies: ["VoinpCore", "VoinpTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoinpEngineTests",
                    dependencies: ["VoinpEngine", "VoinpTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoinpNetTests",
                    dependencies: ["VoinpNet", "VoinpTestSupport"], swiftSettings: strict),
    ]
)
```

### UI を 2 つ作らないための分割

素朴に `VoinpUIKit` を作って `VoinpNet` に依存させると、
**オフライン版のために UI をもう 1 つ書く羽目になる。** それは維持できない。

分割はこうする:

- **`VoinpUIKit`** — 画面の中身のすべて (メニューバー、HUD、設定画面、`AppModel`)。
  `VoinpEngine` までしか依存しない。**ネットワーク側の型を一切知らない**
- **`voinp` / `voinp-offline`** — **合成ルートだけ**を持つ薄い実行ターゲット。
  それぞれ独自のディレクトリに `main.swift` を 1 つ持ち、**中身は 20 行程度**

```swift
// Sources/voinp/main.swift
import VoinpUIKit
import VoinpProviders
import VoinpNet

let gate = EgressGate(policy: ConfigStore.shared.egressPolicy, audit: .shared)
VoinpRoot.run(.base().withLLM([OpenAICompatibleClient(gate: gate)]))
```

```swift
// Sources/voinp-offline/main.swift
import VoinpUIKit

VoinpRoot.run(.base())      // ネットワーク校正なし。EgressGate も存在しない
```

`VoinpUIKit` は `deps.llmClients` が空なら校正 UI を出さないだけでよく、
**`#if` を 1 つも書かずに済む。**

> **`path:` で同じディレクトリを 2 ターゲットに共有させることはできない。**
> SwiftPM が `target 'b' has overlapping sources` で拒否する (実測確認済み)。
> ディレクトリを分けて `main.swift` を 2 つ持つのが正しい形であり、
> 上の構成は実際にビルドと実行を確認してある。

> `VoinpUIKit` が `VoinpNet` を知らないので、
> 設定画面のモデル探索は `LLMClient` プロトコル越しに呼ぶことになる
> ([03](03-refinement.md))。これは接合部の設計として元々正しい。

### なぜ 2 プロダクトを維持するのか

`voinp-offline` は誰もインストールしなくてよい。
**コンパイルし続けること自体が本体ビルドの強制機構**になる ([06](06-privacy.md))。

- 誰かが `VoinpEngine` や `VoinpUIKit` に `VoinpNet` 依存を足すと、
  オフライン版のリンクが壊れて **CI が落ちる**
- `swift build --product voinp-offline` を CI に入れるだけで成立する

検証も実測で確認済み — オフライン版にはネットワーク側のシンボルが入らない:

```sh
swift build --product voinp-offline
nm -u .build/debug/voinp-offline | grep -ci VoinpNet    # => 0
```

**`VoinpEngine` が `VoinpNet` に依存していない**ことがプライバシー保証の実体である
([06](06-privacy.md))。CI でターゲットグラフを assert する。

### `defaultIsolation` がターゲットを分ける理由

`SwiftSetting.defaultIsolation(MainActor.self)` は**ターゲット単位**の設定である。
UI を暗黙 `@MainActor` にしつつ Engine を `nonisolated` にするには分けるしかない。
1 ターゲットに押し込むと UI の全型に `@MainActor` を手で付ける羽目になる。

### SPM の `resources:` を使わない

SPM は実行ファイルの隣に `voinp_VoinpUIKit.bundle` を吐く。
`.app` の中では実行ファイルが `Contents/MacOS/` にいるので、
`Bundle.module` は `Contents/MacOS/voinp_VoinpUIKit.bundle` を指す。
動きはするが場所として間違っており `codesign --deep` を混乱させる。

**組み込みプロンプトとアイコンは Makefile で `Contents/Resources/` に入れ、
`Bundle.main.url(forResource:withExtension:)` で読む。**

## `.app` バンドルの中身

```
build/Voinp.app/Contents/
├── Info.plist
├── PkgInfo                     "APPL????"
├── MacOS/voinp                 SPM が作った実行ファイルをコピー
├── Resources/
│   ├── AppIcon.icns
│   └── Prompts/{raw,clean,polite,slack,translate-en}.md
└── _CodeSignature/CodeResources
```

### Info.plist の必須キー

| キー | 値 | 理由 |
|---|---|---|
| `CFBundleIdentifier` | `com.naotama2002.voinp` | **絶対に変えない。** TCC の許可はこれに紐づく |
| `CFBundleExecutable` | `voinp` | `MacOS/` のファイル名と一致必須 |
| `CFBundleName` / `CFBundleDisplayName` | `Voinp` | システム設定のプライバシー欄に出る名前 |
| `CFBundlePackageType` | `APPL` | |
| `CFBundleShortVersionString` / `CFBundleVersion` | Makefile が注入 | |
| `CFBundleIconFile` | `AppIcon` | |
| `LSMinimumSystemVersion` | `26.0` | |
| **`LSUIElement`** | `true` | メニューバー常駐。Dock アイコンもアプリメニューも出ない |
| **`NSMicrophoneUsageDescription`** | 「音声入力のために…」 | **これが無いと最初の `AVAudioEngine.start()` でプロセスが kill される。** 拒否ではなく kill |
| `NSAppTransportSecurity` → `NSAllowsLocalNetworking` | `true` | loopback / RFC1918 への平文 http ([06](06-privacy.md)) |
| `NSLocalNetworkUsageDescription` | 「社内ネットワーク上の…」 | |
| `LSApplicationCategoryType` | `public.app-category.productivity` | |

**アクセシビリティ用の Info.plist キーは存在しない。**
あの許可はシステム設定にしかなく、それを誘発するのは
`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` だけである。

### entitlements

```xml
<!-- Resources/voinp.entitlements (開発用) -->
<key>com.apple.security.app-sandbox</key>        <false/>
<key>com.apple.security.device.audio-input</key> <true/>
<key>com.apple.security.get-task-allow</key>     <true/>   <!-- 開発専用 -->
```

`audio-input` はサンドボックス外でも **Hardened Runtime が要求する**ので必要。

`get-task-allow` は `lldb` をアタッチするためのもので、
**配布するビルドからは必ず外す。**
entitlements ファイルを 2 種類用意し、Make 変数で切り替える。

### サンドボックスは使わない — 検討の余地はない

1. サンドボックスされたプロセスは**他アプリの AX ツリーを読み書きできない。**
   そのための entitlement は存在しない
   (`com.apple.security.temporary-exception.apple-events` は Apple Events 用であって
   Accessibility 用ではない)
2. セッション全体のキーボードタップ (`CGEvent.tapCreate`) はサンドボックスで拒否される
3. サンドボックスされたアプリの `~/Library/Application Support/voinp/` は
   `~/Library/Containers/com.naotama2002.voinp/Data/...` にリダイレクトされ、
   **「vim で編集できる設定ファイル」という約束が壊れる**

→ **Mac App Store 配布は永久に不可。** README に書いて、後から蒸し返されないようにする。

## 署名と TCC — 開発中に最も刺さる部分

TCC は許可を `(サービス, クライアント ID, コード要件)` の組で保存する。
記録されるコード要件は**署名の仕方で変わる**:

| 署名方法 | designated requirement | 結果 |
|---|---|---|
| **ad-hoc** (`codesign -s -`) | `cdhash H"…"` — そのバイナリ 1 個のハッシュ | **リビルドのたびに cdhash が変わり、マイクとアクセシビリティの許可が静かに revoke される** |
| **実 identity で署名** | `identifier "com.naotama2002.voinp" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …"` | bundle ID と証明書は安定 → **許可が永続する** |

#### 実測（このリポジトリで確認済み）

Apple Development 証明書で署名した `~/Applications/Voinp.app` の designated requirement:

```
designated => identifier "com.naotama2002.voinp" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: <名前> (<TEAMID>)"
              and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
```

ソースを変更して `make install` し直すと:

```
cdhash 1: 4f448e9e21d65a18d4d1bc632e84a1700c2402ef
cdhash 2: a30c5775a02e31dadb9ec4d32f18f621b043ab29   ← 変化する
designated requirement:                              ← 不変
```

**cdhash は毎回変わるが designated requirement は変わらない。**
ad-hoc 署名では DR が cdhash そのものになるため、この差がそのまま
「リビルドのたびに許可が消えるかどうか」になる。

注意: DR に含まれるのは `subject.OU`（チーム ID）ではなく
**`subject.CN`（開発者名を含む証明書の CN）**である。
つまり**開発者ごとに DR が異なる**ので、各自が `make install` する運用と整合する一方、
誰かがビルドした `.app` を配っても TCC の許可は共有されない。

**最初のコミットから、毎回のローカルビルドで実 identity を使う。**
ad-hoc も「あとでちゃんと署名する」も駄目 — 最初の ad-hoc ビルドが
「この作業はこんなに苦痛なのか」という誤った学習を与える。

### identity 選択と同じくらい重要な 3 つの規則

1. **固定パスから起動する。**
   TCC のアクセシビリティ欄はバンドルのパスも追跡する。
   git worktree 内の `./build/Voinp.app` はゴーストの重複エントリを生む。
   `make install` で `~/Applications/Voinp.app` にコピーし、`make run` は必ずそこから起動する
2. **バンドル差し替え前に古いプロセスを kill する。**
   走っているプロセスは古い cdhash を持っており、
   その下でバンドルを入れ替えると TCC の挙動が未定義になる。
   `make run` の 1 行目は `pkill -x voinp || true`
3. **`AXIsProcessTrusted()` を再ポーリングする。**
   この値はプロセスごとに最初の問い合わせ時点でキャッシュされる。
   オンボーディングのシートが出ている間は 1 秒タイマーでポーリングし、
   ユーザーがスイッチを入れた瞬間に UI が反応するようにする。
   そうしないとアプリ再起動が必要になる

### ユニバーサルバイナリ: 作らない — arm64 のみ

macOS 26 は一部の Intel Mac でも動くが、
`SpeechTranscriber` のオンデバイスモデルも `FoundationModels` も **Apple Silicon 専用**である。
x86_64 スライスを入れると、看板機能 2 つが動かないアプリを配ることになる。

arm64 でビルドし、その旨を文書化する。
必要になったら `swift build --triple` を 2 回 + `lipo -create` で Makefile 6 行。

## Makefile

```make
APP           := Voinp
BUNDLE_ID     := com.naotama2002.voinp
VERSION       := 0.1.0
BUILD         := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
CONFIG        := debug
BIN           := $(shell swift build -c $(CONFIG) --show-bin-path)/voinp
APPDIR        := build/$(APP).app
INSTALLDIR    := $(HOME)/Applications/$(APP).app
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning \
                   | awk '/Developer ID Application|Apple Development/ {print $$2; exit}')

.PHONY: build bundle sign verify install run launch test clean reset-permissions

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf $(APPDIR)
	mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Resources
	cp $(BIN) $(APPDIR)/Contents/MacOS/voinp
	printf 'APPL????' > $(APPDIR)/Contents/PkgInfo
	sed -e 's/__VERSION__/$(VERSION)/g' -e 's/__BUILD__/$(BUILD)/g' \
	    -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' \
	    Resources/Info.plist > $(APPDIR)/Contents/Info.plist
	cp    Resources/AppIcon.icns $(APPDIR)/Contents/Resources/
	cp -R Resources/Prompts      $(APPDIR)/Contents/Resources/

sign: bundle
	@test -n "$(SIGN_IDENTITY)" || (echo "codesigning identity が見つかりません"; exit 1)
	codesign --force --sign $(SIGN_IDENTITY) \
	         --entitlements Resources/voinp.entitlements \
	         --options runtime --generate-entitlement-der \
	         --timestamp=none \
	         $(APPDIR)

# 06-privacy.md の検証レシピ
verify: sign
	codesign --verify --strict --verbose=2 $(APPDIR)
	codesign -dv --entitlements - $(APPDIR) 2>&1 | sed -n '1,25p'
	otool -L $(APPDIR)/Contents/MacOS/voinp
	nm -u $(APPDIR)/Contents/MacOS/voinp | grep -iE 'CFNetwork|NWConnection|getaddrinfo' || true
	@test ! -s Package.resolved || (echo "サードパーティ依存が入っています"; exit 1)

install: sign
	pkill -x voinp || true
	rm -rf $(INSTALLDIR)
	ditto $(APPDIR) $(INSTALLDIR)

# バイナリを直接起動するので stdout/stderr がターミナルに出る。
# TCC は実行ファイルのパスから .app を辿るので、権限は通常どおり効く。
run: install
	$(INSTALLDIR)/Contents/MacOS/voinp

launch: install
	open -n $(INSTALLDIR)

test:
	swift test

reset-permissions:
	tccutil reset Accessibility $(BUNDLE_ID) || true
	tccutil reset Microphone    $(BUNDLE_ID) || true
```

開発では `--timestamp=none` にする。
セキュアタイムスタンプは Apple へのネットワーク往復が必要で、毎ビルドに数秒足す。

`make run` が素のバイナリを起動するのは意図的で、
**`.xcodeproj` なしで得られる最速の開発ループ**である。
`print` / `OSLog` がターミナルに出つつ、TCC はバンドルされたアプリとして扱う
(実行ファイルのパスから責任バンドルを辿るため)。

## 配布

**各自が clone して `make install` する**前提 ([00](00-overview.md))。

- 自分の Apple Development 証明書で署名するので、TCC の許可が安定する
- notarize 不要、Developer ID 不要、Gatekeeper の右クリック回避も不要
- 更新はアプリ内機構ではなく `git pull && make install`

**未決:** エンジニア以外にも配るなら Developer ID を取得して notarize + stapler が必要になる。
そのときは `make release` を足す (`--timestamp` 付き署名 →
`xcrun notarytool submit` → `xcrun stapler staple` → DMG)。

## テスト

**Swift Testing を使う。XCTest ではない。**
Swift 6.2 ネイティブで、`@Test(arguments:)` が状態機械のテーブル駆動テストをそのまま書け、
async / actor の扱いが一級で、`.enabled(if:)` で統合テストを綺麗にゲートできる。
`XCTestExpectation` 的な run loop の回し込みが必要な箇所がない。

### GUI もマイクも権限も不要なテスト

| スイート | 内容 | 目安 |
|---|---|---|
| `SessionMachineTests` | `(phase, event) → (phase, [action])` の全遷移 | 40 |
| `HotkeyInterpreterTests` | 合成した `(keyCode, flags, instant)` 列 → コマンド。ホールド / タップ / ダブルタップ / 修飾キー単独 / hybrid 昇格 / 抑止判断 | 30 |
| `KeyComboTests` | パース ↔ 整形の往復、`CGEventFlags` ↔ `Modifiers` (左右のデバイスビット含む) | 20 |
| `TranscriptBufferTests` | 暫定の置換、確定の追記、範囲の重なり、順序逆転 | 12 |
| `SettingsTests` | decode → encode → decode の不動点、欠損キーは既定値、**壊れたファイルでクラッシュせず上書きもしない** | 12 |
| `PromptLibraryTests` | `prompts/*.md` の front-matter、プリセット解決、組み込みの上書き | 8 |
| `RefinementGuardTests` | 修復 6 種と棄却 8 種。`英訳` プリセットで `scriptShift` が無効化されること | 25 |
| `PrivacyPostureTests` | **ゴールデンテスト。既定設定が `.offline`、設定エラーで `.denyAll`** ([06](06-privacy.md)) | 10 |
| `PasteboardRestoreTests` | `FakePasteboard` に対して、**`changeCount` が動いていたら復元しない**ことを assert | 8 |
| `RefinementPipelineTests` | `FakeRefiner` が throw / ハング → 出力が生原稿と一致する (テキストを失わない) | 6 |
| `EngineContractTests` | 同一スイートを `FakeTranscriptionProvider` と**実 `SpeechTranscriptionProvider`** の両方に流す | 10 × 2 |

**`EngineContractTests` が接合部を作った見返り**である。
実 Speech パイプラインを**マイクなしで**端から端まで検証できる
(同梱の 3 秒の日本語 WAV を `SpeechAnalyzer(inputAudioFile:modules:)` で流す)。
ヘッドレスの CI ランナーで動き、step 2 でクラウドエンジンが入っても同じ検証が効き続ける。

### フェイク (`VoinpTestSupport`)

`FakeTranscriptionProvider` (`(遅延, TranscriptionEvent)` の台本) ・
`FakeRefiner` (`.identity` / `.throws` / `.slow`) ・
`RecordingInserter` (呼び出しを記録) ・
`FakePasteboard` (`changeCount` を手で動かせる) ・
`FakeHotkeySource` (生イベントを流し込む) ・
`FakeAudioSource` (WAV からチャンクを出す) ・
`InMemoryCredentialStore`。

テストのためだけにプロトコルを導入するのが正当化できる唯一の箇所は
**`PasteboardProtocol`** (`changeCount` / `clearContents` / `items` / `write`)。
復元の不変条件は微妙で、簡単に退行するため、単体で検証できる価値が勝る。

### CI

実 Speech / 実 AX を使うテストはタグを付けてゲートする:

```swift
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOINP_INTEGRATION"] != nil))
```

**クリーンなランナーでの `swift test` は、権限ゼロで Core + フェイクを回して緑になること。**

CI で追加に assert すること:

- `Package.resolved` が空 ([06](06-privacy.md))
- ターゲットグラフが宣言した許可リストと一致 (特に `VoinpEngine` → `VoinpNet` がないこと)
- `Sources/VoinpNet/` 以外に `URLSession` が現れない

### 自動化できない手動チェック (`docs/manual-tests.md`)

- `tccutil reset` した状態からの権限付与フロー
- Slack / VS Code / Terminal.app / メモ / Safari / Xcode / iTerm2 への挿入
- 録音中の AirPods 接続・切断 (デバイス経路変更)
- HUD がテキスト欄からフォーカスを奪わないこと
- 初回モデルダウンロードの途中でネットワークを切る
- `.listening` 中のディスプレイスリープ・復帰
- Fn キーとシステム設定のディクテーションの衝突
- **ペーストボード方式で挿入した内容が iPhone に同期されないこと** ([05](05-ui-input.md) の未決事項)

## 設定ファイルの扱い

### 全体像

step 1 の全フィールド。step 2 で足すものはコメントで示す。
この内容がそのまま `config.example.jsonc` として同梱される ([04](04-prompts.md), [06](06-privacy.md))。

```jsonc
{
  // 必ず先頭。マイグレーション判定に使う。
  "schemaVersion": 1,

  "hotkey": {
    "binding": "ctrl+opt+space",   // "rightCommand" / "fn" / "doubleTap:rightCommand" も可
    "behavior": "hybrid",          // "hold" | "toggle" | "hybrid"
    "holdThresholdMs": 200,        // hybrid のホールド判定
    "cancelKey": "escape"
  },

  "audio": {
    "inputDeviceUID": null,        // null = システム既定の入力デバイス
    "playFeedbackSounds": true,
    "maxRecordingSeconds": 120,    // 安全弁。超過時は自動確定
    "minRecordingMs": 250          // これ未満はキャンセル扱い (空挿入を防ぐ)
  },

  "transcription": {
    "provider": "apple.speechanalyzer",   // step2: "openai.whisper" | "deepgram" ...
    "module": "dictation",                // "dictation" | "transcription" (02 のスパイクで確定)
    "locale": "ja-JP",
    "reserveLocales": ["ja-JP", "en-US"], // 未予約だと OS が資産を削除しうる
    "modelRetention": "processLifetime",  // "whileInUse" | "lingering" | "processLifetime"
    "showPartialResults": true,
    "punctuation": "automatic",           // "automatic" | "off"
    "termHints": ["kintone", "サイボウズ", "Garoon", "voinp"],
    "termHintsFile": null                 // 大きい辞書は 1 行 1 語の別ファイルへ
  },

  "refinement": {
    "enabled": false,                      // 既定オフ
    "provider": "openai-compatible",       // "none" | "openai-compatible" | "apple.foundationmodels"
    "defaultPresetID": "clean",
    "softDeadlineMs": 1500,
    "hardDeadlineMs": 4000,
    "maxRetries": 1,
    "disableAfterConsecutiveFailures": 3,
    "temperature": 0.1,
    "maxOutputTokens": 1024,
    "stripThinkTags": true,

    "openaiCompatible": {
      // loopback / 社内 LAN / 社内 HTTPS サーバのいずれも指定できる
      //   "http://127.0.0.1:1234/v1"      手元の LM Studio
      //   "https://10.1.2.3/v1"           社内 LAN / VPN
      //   "https://llm.example.co.jp/v1"  社内サーバ（到達範囲はインターネット経由）
      "baseURL": "http://127.0.0.1:1234/v1",  // 正規化後の値を保存する
      "model": "qwen3-8b-instruct",
      // 誰が運用しているか。**表示専用の申告であり、送信許可は広げない。**
      // 許可を決めるのは privacy.allowedEgressClasses（到達範囲）だけ。
      "operatorKind": "self-hosted",          // "self-hosted" | "vendor"
      "requiresAPIKey": false,   // true なら Keychain から読む。キー本体はここに書かない
      "extraHeaders": {},        // Authorization 等は書けない (起動時に拒否)
      "extraBody": {}            // 例: {"chat_template_kwargs": {"enable_thinking": false}}
    }
  },

  "insertion": {
    "strategy": "paste",           // "paste" | "accessibility" | "keystroke" | "auto"
    "restoreClipboard": true,
    "pasteRestoreDelayMs": 250,
    "pasteKeyCode": null,          // null = 現在のレイアウトから "v" を逆引き
    "trailingSpace": false,
    "overrides": {}                // 例: {"com.microsoft.VSCode": {"pasteRestoreDelayMs": 450}}
  },

  "privacy": {
    "allowNetwork": false,                   // マスタースイッチ
    // 到達範囲の上限。**強制に使う唯一の軸**。
    // 社内サーバ (https://llm.example.co.jp) を使うなら publicInternet が必要になる。
    // 「インターネットに送る」ではなく「この Mac とネットワークの外まで届く」の意味。
    "allowedEgressClasses": ["loopback"],    // "loopback" | "privateNetwork" | "publicInternet"
    "extraAllowlistHosts": [],
    "auditLog": { "enabled": true, "toDisk": true, "maxEntries": 500 },
    "updateCheck": "never"                   // "never" | "manual"。"auto" は存在しない
  },

  "history": {
    "keepLastTranscripts": 0       // 既定 0 = 保存しない
  },

  "ui": {
    "showMenuBarPrivacyIndicator": true,
    "hudPosition": "bottomCenter", // "bottomCenter" | "hidden"
    "hudShowText": true            // false にすると認識テキストを HUD に出さない
  }
}
```

**既定値のまま起動すると `PrivacyPosture.Level.offline` になる** ([06](06-privacy.md))。
これはゴールデンテストで固定する。

秘密は 1 つもこのファイルに現れない。API キーは Keychain のみ ([03](03-refinement.md))。

### 形式

Foundation には「コメントが書けて・人が編集できて・`Codable` で往復できる」形式がない。
TOML も YAML も依存が要る。

**JSON を使い、読み込み時に `JSONDecoder.allowsJSON5 = true` を立てる。**
JSON5 は `//` コメントと末尾カンマを受け付けるので、手書きのコメントが壊れない。

書き込み時にコメントは**保存できない**。解決策:

1. 読みは JSON5 で寛容に
2. アプリが書くのは**ユーザーが設定画面で何かを変えたときだけ**。
   初回に一度だけ「設定ファイルを保存するとコメントが失われます」と警告する
   (「今後表示しない」付き)
3. `config.example.jsonc` (全項目にコメント付き) を同梱し、
   メニューに「注釈付きサンプルを開く」を置く。**これがドキュメントの正本**

コメント保存型の JSON ラウンドトリッパは書かない。
400 行の微妙なコードで、2 が社会的に解決している問題である。

`ConfigCodec` プロトコルの裏に置くので、後で TOML に移るのは
1 つの conformance 追加 + 依存 1 つで済む。

### 配置

```
~/Library/Application Support/voinp/
├── config.json           # 設定本体
├── config.example.jsonc  # 初回に 1 度だけ書き出す。読まれない。全項目コメント付き
├── prompts/              # ユーザー定義プリセットのみ (組み込みは .app 内)
│   ├── base.md
│   └── slack.md
└── logs/
    └── egress.jsonl
```

ファイルは `0600`、ディレクトリは `0700`
(設定には社内ホスト名が入りうる)。

### 書き込み

`actor ConfigStore` が直列化し、**500 ms デバウンス**する
(設定のスライダーが毎秒 60 回書き込まないように)。

**同じディレクトリの** `config.json.tmp` に書き → `fsync(2)` → `rename(2)`
(または `FileManager.replaceItemAt`)。
`Data.write(to:options:.atomic)` は tmp+rename をするが **`fsync` はしない。**

### 壊れた設定

- **黙ってリセットしない。** ユーザーはこのファイルを調整している
- **構文エラー:** ファイルに触らず、メモリ上の既定値で動き、
  目に見える「設定エラー」状態に入る — メニューバーに警告バッジ、
  メニューにエラーの位置 (`DecodingError` の `codingPath`) と
  「設定ファイルを開く」「再読み込み」
- **エラー状態の間は `EgressPolicySnapshot = .denyAll`。fail closed。**
  UI にもそう書く:「設定エラーのため通信を停止しています」([06](06-privacy.md))
- **部分的・意味的なエラー** (未知のプロバイダ ID、壊れたベース URL、無いプリセット) は
  寛容にデコードする。手書きの `init(from:)` で `decodeIfPresent` + 既定値、
  throw せず `[ConfigIssue]` に貯める。アプリは動き、設定画面が問題を列挙する。
  `ui.hudPosition` の typo でディクテーションが止まってはいけない
- **未知のトップレベルキーを書き込み時に保存する**
  (生の `[String: JSONValue]` を型付き値と並べて持ち、保存時にマージ)。
  ダウングレードの往復で将来のキーが消えないように

### マイグレーション

```swift
public struct Migration: Sendable {
    public let from: Int, to: Int
    public let apply: @Sendable (inout JSONValue) throws -> Void
}
```

- マイグレーションは**生の JSON に対して**行う。型付き構造体に対して行わない。
  型付き構造体は現行バージョンのぶんだけ存在する。
  **これがマイグレーションを腐らせない唯一の判断** — `ConfigV1`, `ConfigV2`, … を
  コンパイルし続ける必要がなくなる
- マイグレーション前に `config.v{N}.backup.json` にコピー (直近 3 つ保持)
- **`schemaVersion` が現行より大きければ、書き込みを拒否する。**
  メモリ上は既定値で動き、「設定ファイルがこのバージョンより新しい形式です」と出し、
  ファイルには一切触らない。ダウングレードで他人の設定を壊すのは許されない
- `schemaVersion` 欠損は 1 とみなす

### 外部編集の監視

手で編集できる設定を謳う以上、手編集は想定されたワークフローであり、
「編集が反映されない」が最大の不満になる。

- **ファイルではなくディレクトリを監視する。**
  アトミックな置換は inode を入れ替えるので、ファイルの fd に張った
  `DispatchSource` は最初の外部保存で死ぬ。
  `DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write])`
- 300 ms デバウンス
- 自分の書き込みによる再読み込みを抑止するため、
  `(st_mtimespec, st_size, sha256)` を `ConfigStore` が最後に書いた値と比較する
- 外部変更時: 再読み込み → 検証 → 差分。
  `privacy.*` が変わったら `PrivacyPosture` を再計算して
  「設定を再読み込みしました — 送信先: なし」と一時通知。
  **ディクテーション中は再読み込みしない。** セッション終了までキューに入れる
- 「設定を再読み込み」のメニュー項目も残す。
  ネットワークボリュームや一部エディタの保存方式で監視は取りこぼす

`prompts/` も同じ監視を持つが、ディクテーション中の制限はない
([04](04-prompts.md))。

## 実装順序 (再掲)

1. `Package.swift` + `Makefile` + Info.plist + entitlements →
   `MenuBarExtra` が「Hello」と出すだけの空アプリ。
   **`make install` → アクセシビリティを手で許可 → 2 回リビルド →
   許可が残っていることを確認。**
   これが署名戦略全体の検証であり、ここが崩れたら他は全部無意味。**最初にやる**
2. `VoinpCore` の純粋ロジックと全テスト (macOS API ゼロ、CI で緑)
3. `EventTapHotkeySource` + 権限オンボーディング + キーレコーダ
4. `AudioCapture` + `SpeechModelInstaller` + `SpeechTranscriptionProvider`
   (`DictationTranscriber` vs `SpeechTranscriber` のスパイクをここで済ませる)
5. `PasteInserter` + `InsertionTargetResolver` (実アプリで確認)
6. HUD + 設定画面
7. `VoinpNet` + `EgressGate` + OpenAI 互換クライアント + 校正
