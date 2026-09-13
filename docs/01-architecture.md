# 01. アーキテクチャ

## ターゲット構成

```
voinp              合成ルート (約 20 行)                      MainActor
│                  Dependencies を組み立てて VoinpRoot.run() を呼ぶだけ
├─ VoinpUIKit      SwiftUI / MenuBarExtra / NSPanel HUD / 設定  MainActor
│  └─ VoinpEngine  音声 / Speech / AX / CGEvent / Keychain      nonisolated
│     └─ VoinpCore 純粋ロジック                                  nonisolated
├─ VoinpProviders  OpenAI 互換クライアント                       nonisolated
│  └─ VoinpNet     EgressGate — 唯一の URLSession               nonisolated
└─ VoinpNet           └─ VoinpCore

voinp-offline      合成ルート (約 3 行)                        MainActor
└─ VoinpUIKit      ← VoinpNet も VoinpProviders も含まない
   └─ VoinpEngine
      └─ VoinpCore
```

依存は厳密に下向き。守るべき不変条件は 2 つ:

- **`VoinpEngine` は `VoinpNet` に依存しない**（音声を扱う層がネットワークを知らない）
- **`VoinpUIKit` も `VoinpNet` に依存しない**（UI を 2 つ作らずにオフライン版を成立させるため）

ネットワーク側を知っているのは**合成ルートの実行ターゲットだけ**である。
だから `voinp-offline` は `VoinpUIKit` をそのまま再利用でき、UI の重複実装が発生しない
([07](07-build.md))。

### ターゲットを分ける理由

1. **`SwiftSetting.defaultIsolation(MainActor.self)` はターゲット単位の設定**である。
   UI を暗黙 `@MainActor` にしつつ Engine を `nonisolated` にするには、分けるしかない。
   1 ターゲットに押し込むと UI の全型に `@MainActor` を手で付けることになる。

2. **ネットワークコードの隔離が、プライバシー保証の実体**になる。
   音声を扱う `VoinpEngine` が `VoinpNet` にリンクすらしていないことを CI で assert できる
   ([06](06-privacy.md))。「送らない」がポリシーではなくコードの不在になる。

3. `VoinpCore` が AppKit も Speech も import しないことで、**マイクも画面も権限もなしに
   ロジックの大半をテストできる** ([07](07-build.md))。

### 各ターゲットの責務

| ターゲット | 持つもの | 持たないもの |
|---|---|---|
| `VoinpCore` | セッション状態機械、ホットキー解釈、書き起こしバッファ、設定モデル、プロンプト組み立て、出力ガード、`PrivacyPosture`、各種プロトコル | I/O 全般 |
| `VoinpEngine` | `AVAudioEngine`、`SpeechAnalyzer`、`AXUIElement`、`CGEvent`、Keychain、設定ファイル読み書き、`DictationCoordinator` | URLSession、SwiftUI |
| `VoinpNet` | `EgressGate`、ホスト分類、プロキシ判定、監査ログ、唯一の `URLSession` | 音声、AX、プロバイダ固有の知識 |
| `VoinpProviders` | OpenAI 互換クライアント、`EndpointProbe` | 音声、AX |
| `VoinpUIKit` | `MenuBarExtra`、HUD パネル、設定画面、`AppModel` | ビジネスロジック、**ネットワーク側の型** |
| `voinp` / `voinp-offline` | `Dependencies` の組み立てのみ | それ以外すべて |

設定画面はモデル一覧を取りに行く必要があるが、
**`VoinpUIKit` は `LLMClient` プロトコル越しに呼ぶ**ので `VoinpNet` を import しない。
実装を注入するのは合成ルートである。
オフライン版では `Dependencies.llmClients` が空になり、UI は校正の項目を出さない。

## パイプライン

```
 ┌ CGEvent tap (専用 run loop スレッド) ──▶ HotkeyInterpreter ──▶ SessionCommand
 │
 ▼
DictationCoordinator (actor) ── SessionMachine を所有し、唯一の真実を持つ
 │
 ├─▶ AudioCapture (actor)
 │     AVAudioEngine.installTap  [tap スレッド]
 │       └ AVAudioConverter → AudioChunk
 │           └ AsyncStream<AudioChunk>  bufferingNewest(256)   ← 損失許容
 │
 ├─▶ TranscriptionSession (actor)
 │     AnalyzerInput ──▶ SpeechAnalyzer (actor) ──▶ transcriber.results
 │       └ AsyncThrowingStream<TranscriptionEvent>             ← 損失不可
 │           .partial(String)     … 直前の暫定結果を丸ごと置換
 │           .finalized(Segment)  … 確定分に追記
 │
 ├─▶ TranscriptBuffer            確定分 + 暫定分をマージ (coordinator actor 内)
 │     └ 20 Hz にスロットルした snapshot ──▶ @MainActor AppModel ──▶ HUD
 │
 ├─▶ TextRefiner                 生原稿 → LLM → 整形テキスト (失敗時は生原稿)
 │
 └─▶ TextInserter                ⌘V 合成 or AX、フォアグラウンドアプリへ
```

### 2 つのストリームで方針が違う

| ストリーム | バッファリング | 理由 |
|---|---|---|
| 音声入力 | `.bufferingNewest(256)` — **損失許容** | 認識が詰まった場合に無制限にメモリを食わせない。256 × 85 ms ≒ 22 秒 ≒ 700 KB |
| 認識結果 | **損失不可**。coordinator が `for try await` で直接消費 | `.finalized` を 1 つ落とすと文が欠ける |
| HUD 更新 | `.bufferingNewest(1)` / 20 Hz — **損失許容** | 描画が追いつかなくても最新だけ映ればよい |

真実は coordinator actor の `TranscriptBuffer` にあり、UI にはその劣化コピーだけを流す。
この分離が、`@Published` を 70 個持つ ViewModel を避ける具体的な方法である。

## セッション状態機械

`VoinpCore` に置く純粋な reducer。macOS API を一切触らないため、
**GUI もマイクも権限もなしに全遷移をテストできる**。

```swift
public enum SessionPhase: Sendable, Equatable {
    case idle
    case installingModel(progress: Double)   // 初回のみ
    case arming                              // マイク起動 + prepareToAnalyze + 挿入先確定
    case listening(TranscriptSnapshot)
    case finalizing                          // 音声停止、残りの確定待ち
    case refining
    case awaitingModifierRelease(text: String)  // PTT の修飾キーがまだ押されている
    case inserting
    case failed(SessionError)
}

public enum SessionEvent: Sendable, Equatable {
    case startRequested(target: InsertionTarget)
    case stopRequested
    case cancelRequested
    case modelProgress(Double)
    case modelReady
    case audioStarted
    case transcript(TranscriptionEvent)
    case transcriptionFinished(text: String)
    case refinementFinished(text: String)
    case modifiersReleased
    case insertionFinished(InsertionOutcome)
    case failed(SessionError)
    case dismissRequested
}

public enum SessionAction: Sendable, Equatable {
    case installModel(Locale)
    case startCapture(InsertionTarget)
    case stopCaptureAndFinalize
    case abortEverything
    case refine(String)
    case waitForModifierRelease(String)
    case insert(String, into: InsertionTarget)
    case copyToPasteboardAsFallback(String)
    case showHUD, hideHUD
    case play(Feedback)                      // .start / .stop / .cancel / .error
    case scheduleDismiss(after: Duration)
}

public struct SessionMachine: Sendable {
    public private(set) var phase: SessionPhase = .idle
    public mutating func handle(_ event: SessionEvent,
                                at now: ContinuousClock.Instant) -> [SessionAction]
}
```

**Clock は注入しない。** `handle` が時刻を引数で受け取る。
これで `TestClock` のような仕掛けなしに完全に決定的なテストが書ける。

### 正常系

```
idle ──startRequested──▶ arming ──audioStarted──▶ listening
                                                    │
                                          stopRequested
                                                    ▼
                                               finalizing
                                                    │
                                       transcriptionFinished
                                                    ▼
                                                refining
                                                    │
                                        refinementFinished
                                                    ▼
                                     awaitingModifierRelease
                                                    │
                                          modifiersReleased
                                                    ▼
                                               inserting ──▶ idle
```

### 明示的に決めておく端条件

| 状況 | 規則 |
|---|---|
| `arming` 中に `stopRequested` (素早いタップ) | 録音は続行。合計 250 ms 未満なら `cancelRequested` 扱いにして「短すぎます」を出す。空挿入を防ぐ |
| `refining` / `inserting` 中に再度ホットキー | 無視して `play(.error)`。**セッションは絶対に重ねない** |
| `arming` 時点で Secure Input 検知 | `failed(.secureInputActive)`。「パスワード欄にフォーカスしています」 |
| `transcriptionFinished` のテキストが空 | 校正も挿入もスキップして `idle` へ。`play(.cancel)` |
| 校正が例外 / タイムアウト | `refinementFinished(text: 生原稿)`。**校正の失敗でユーザーの発話を失わない** |
| 挿入が例外 | `copyToPasteboardAsFallback` + `failed(.insertionFailed)`。テキストは必ずどこかに残す |
| `awaitingModifierRelease` が 500 ms 超 | **挿入しない。** HUD に「修飾キーを離してください」を出して待ち続ける ([05](05-ui-input.md)) |
| `awaitingModifierRelease` が 3 秒超 | `copyToPasteboardAsFallback` + `failed(.modifiersStuck)`。誤った修飾キー付きでキーを送らない |
| arming 時と挿入時でフォアグラウンドアプリが変わった | 現在の最前面に挿入する (ユーザーが意図的に切り替えた)。差異はログに残す |
| `failed` | 4 秒後に自動で `idle` へ |

`awaitingModifierRelease` が状態として存在するのは、
push-to-talk で ⌃⌥ を押したまま ⌘V を合成すると ⌃⌥⌘V になってしまうため
([05](05-ui-input.md) の「勘所 3」)。

## TranscriptBuffer

確定結果と暫定結果をマージし、セッション中の「唯一の真実」を保つ。
`DictationCoordinator` actor の内部にのみ存在し、UI へは `snapshot()` を
スロットルして流す。実装は `Sources/VoinpCore/Transcript/TranscriptBuffer.swift`。

### 不変条件

1. **`.partial` は暫定分を置換する。決して追記しない。**
   暫定結果は次の結果で丸ごと置き換わる前提で送られてくる。
2. **`.finalized` は確定分に追記し、暫定分を破棄する。**
   暫定分は同じ音声区間のより粗い推定なので、確定が来たら残してはいけない。
3. **既存セグメントと音声区間が重なる確定結果は捨てる。**
   エンジンによっては同じ区間を再確定して送るため、素朴に追記すると文が二重になる。
4. **到着順は保証されない。** `audioRange` があれば開始時刻順に整列して連結する。

### 実装時に踏んだ罠

不変条件 3 を「確定済み終端 `committedEnd` より前なら捨てる」と実装すると、
**遅れて届いた前半の区間を誤って破棄する**（不変条件 4 と衝突する）。

```
[2s–3s] "後半" が先に到着 → committedEnd = 3s
[0s–1s] "前半" が後から到着 → lowerBound(0) < committedEnd(3) なので捨てられる
結果: "後半" だけが残る
```

判定は終端との比較ではなく、**既存セグメントとの実際の重なり**で行う。
`TranscriptBufferTests` の「到着順が逆でも音声区間順に整列される」がこれを固定している。

## エラー型

`VoinpError`（`Sources/VoinpCore/VoinpError.swift`）が下位レイヤの失敗、
`SessionError`（`Sources/VoinpCore/Session/SessionError.swift`）が
HUD に出す粒度のセッション失敗。

`SessionError` には `textIsOnPasteboard` があり、
`.insertionFailed` と `.modifiersStuck` で `true` になる。
**ユーザーの言葉が必ずどこかに残る**という保証を型で表現している箇所なので、
新しいケースを足すときはここを更新すること。

送信ゲートの拒否理由は `EgressDenialReason` に集約し、
そのまま監査ログに載る（テキストを保持できるフィールドは持たせない）。

## Swift 6 Strict Concurrency の isolation マップ

| コンポーネント | isolation | 理由 |
|---|---|---|
| `AudioCapture` | `actor` | `AVAudioEngine` を所有。tap の中身のみ `nonisolated` |
| tap コールバック本体 | `nonisolated` / tap スレッド | 変換して `yield` するだけ。10 行以内に保つ |
| `TranscriptionSession` | `actor` | `SpeechAnalyzer` (これ自体 actor) を包む |
| `TextRefiner` の LLM クライアント | `actor` | `LanguageModelSession` は `Sendable` ではない |
| `AccessibilityInserter` | **`actor`。`@MainActor` にしない** | AX 呼び出しは既定 6 秒ブロックしうる。メインに置くとビーチボール |
| `PasteInserter` | `actor` | ただしペーストボード操作だけ `@MainActor` にホップ |
| `EventTapHotkeySource` | `final class: @unchecked Sendable` / 専用スレッド | tap コールバックが C 関数ポインタ |
| `EgressGate` | `actor` | 送信ポリシー判定の直列化 |
| `DictationCoordinator` | `actor` | `SessionMachine` を所有する唯一の真実 |
| `AppModel` | `@MainActor @Observable` | coordinator の劣化ビュー |
| HUD / メニューバー / 設定 | `@MainActor` | AppKit / SwiftUI |

### 最重要: AX をメインスレッドに置かない

`AXUIElementSetAttributeValue` は相手アプリがハングしていると
**既定 6 秒ブロックする**。専用 actor に置き、さらに

```swift
AXUIElementSetMessagingTimeout(element, 0.5)
```

でタイムアウトを絞る。両方やる。

## AppModel — 神 ViewModel を避ける形

```swift
@MainActor @Observable
final class AppModel {
    private(set) var phase: SessionPhase = .idle
    private(set) var snapshot: TranscriptSnapshot = .empty
    private(set) var level: Float = 0
    private(set) var permissions: PermissionStatus = .unknown
    private(set) var privacy: PrivacyPosture = .offline
    var settings: Settings

    private let coordinator: DictationCoordinator
    private var updateTask: Task<Void, Never>?

    init(dependencies: Dependencies = .live) {
        self.coordinator = DictationCoordinator(dependencies)
        self.settings = dependencies.configStore.current
        updateTask = Task { [weak self] in
            for await update in await coordinator.updates { self?.apply(update) }
        }
    }

    private func apply(_ u: CoordinatorUpdate) { /* 1 つの switch、20 行程度 */ }
}
```

**格納プロパティ 6 つ、入力ストリーム 1 本、`switch` 1 つ。**
`ServiceContainer` のような DI シングルトンは作らない。
合成ルートは `Dependencies` 構造体 (プロトコル型のフィールド約 7 個、`.live` / `.preview`) で、
すべてコンストラクタ注入する。

## 差し替え可能にする接合部

すべて `VoinpCore/Ports/` に置く。詳細は各 docs を参照。

| プロトコル | 用途 | 詳細 |
|---|---|---|
| `TranscriptionProvider` / `TranscriptionSession` | STT の差し替え。step 2 のクラウド STT はここに載る | [02](02-transcription.md) |
| `LLMClient` | 校正 LLM の差し替え。OpenAI 互換 / Anthropic / Gemini | [03](03-refinement.md) |
| `TextInserter` | 挿入戦略 (ペースト / AX / キーストローク) | [05](05-ui-input.md) |
| `HotkeySource` | テストで合成イベントを流し込む口 | [05](05-ui-input.md) |
| `CredentialStore` | Keychain。テストではインメモリ | [03](03-refinement.md) |
| `ConfigCodec` | 設定のシリアライズ形式 | [07](07-build.md) |

接合部を作る唯一の正当化は**テスト可能性**である。
`TranscriptionProvider` の元は取れている: 同じ契約テストを
フェイクと実 `SpeechAnalyzer` の両方に流し、後者は同梱の ja WAV で駆動するので
**マイクなしで実パイプラインを検証できる** ([07](07-build.md))。

## 実装順序

1. `Package.swift` + `Makefile` + Info.plist + entitlements
   → `MenuBarExtra` が「Hello」と出すだけの空アプリを実証明書で署名し `~/Applications` に配置。
   **2 回リビルドしてもアクセシビリティ許可が消えないことを確認する。**
   これが署名戦略全体の検証であり、ここが崩れると後の全部が無意味になる
2. `VoinpCore`: `SessionMachine` / `HotkeyInterpreter` / `KeyCombo` / `TranscriptBuffer` と各テスト。
   macOS API ゼロ、CI で全部緑
3. `EventTapHotkeySource` + アクセシビリティ権限のオンボーディング + キーレコーダ
4. `AudioCapture` + `SpeechModelInstaller` + `SpeechTranscriptionProvider`。
   ここで `DictationTranscriber` vs `SpeechTranscriber` のスパイクを済ませる
5. `PasteInserter` + `InsertionTargetResolver`。Slack / VS Code / ターミナル / メモで実機確認
6. HUD + 設定画面
7. `VoinpNet` + `EgressGate` + OpenAI 互換クライアント + 校正

1 が最大のリスクなので最初に置いている。

## 勘所: セッションの世代でキャンセルとの競合を断つ

`DictationCoordinator` は actor だが、**actor は中断点で他のメッセージを受ける。**
`startCapture` はモデル準備・セッション開始・フォーマット取得と何度も await するので、
待っている間に HUD からキャンセルされ、状態機械が idle に戻ることがある。
以前はそこから戻ったあと素通しで録音を開始しており、
**キャンセル済みなのにマイクが開く**経路があった。

`generation` を持ち、開始とキャンセルのたびに進める。
中断から戻るたびに照合し、変わっていれば作りかけを畳んで降りる。

```swift
let g = beginGeneration()
...
guard isCurrent(g) else { await s.cancel(); return }
```

LLM の応答待ち (`refine`) も数秒あるので同じ扱いにする。

**actor だから安全、ではない。** 排他されるのは 1 回の中断なし実行区間だけで、
await をまたいだ不変条件は自分で守る必要がある。
`CancellationRaceTests` が、世代チェックを外すと落ちることまで含めて固定している。
