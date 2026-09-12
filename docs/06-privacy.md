# 06. プライバシー

> **旗印: デフォルト起動状態では、音声データを外部に一切送信しない。**

この章はその約束を「設定の既定値」ではなく**検証可能な性質**にするための設計を書く。

## 脅威モデル

守る相手は悪意ある攻撃者ではなく、**自分たちの不注意**である。
社内ツールとして同僚に使ってもらうとき、「たぶん大丈夫」では足りない。

| 想定する事故 | 対策 |
|---|---|
| 実装ミスで音声がクラウド STT に流れる | 音声を扱うターゲットがネットワークターゲットにリンクしない ([D.1](#d1-最強-バイナリにネットワークコードが入っていない)) |
| 依存ライブラリが勝手に通信する | **サードパーティ依存ゼロ** ([D.6](#d6-最も検証しやすい主張-サードパーティ依存ゼロ)) |
| 設定ミスで意図しない先に送る | 許可ホストを設定から**導出**する。手で書けない ([D.4](#d4-ポリシーは導出する)) |
| 設定が壊れたときに素通しになる | **fail closed**。パース失敗 → 全拒否 ([D.4](#d4-ポリシーは導出する)) |
| ログに書き起こしが残る | `EgressRecord` にテキストを持てる型がない。`OSLog` は `privacy: .private` |
| ペーストボード経由で iPhone に同期される | マーカー付与 + 実測確認 + キーストローク方式の逃げ道 ([D.9](#d9-やらないこと)) |
| DNS 解決でホスト名が漏れる | loopback の**リテラル IP** だけが真にゼロ egress だと明記する ([D.4](#d4-ポリシーは導出する)) |

## D.0 前提: App Sandbox は使えない

**カーネルが強制する唯一の答え**は「App Sandbox を有効にし、
`com.apple.security.network.client` を与えない」だった。これは使えない。

テキスト挿入には他プロセスへの Accessibility アクセスと `CGEvent` セッションタップが要るが、
サンドボックスはどちらも拒否する ([05](05-ui-input.md), [07](07-build.md))。

→ **Mac App Store 配布は永久に不可。** README に明記する。

サンドボックスがない以上、プロセスはどの行からでもソケットを開ける。
「構造的に強制する」は、実際に届けられるもので定義し直す必要がある。以下、強度の高い順。

## D.1 最強: バイナリにネットワークコードが入っていない

```
Sources/
  VoinpCore/      設定, PrivacyPosture, 値型                 deps: —
  VoinpNet/       EgressGate, ホスト分類, 監査, 唯一の URLSession   deps: VoinpCore
  VoinpEngine/    音声, Speech, AX, CGEvent, Keychain        deps: VoinpCore   ← VoinpNet なし
  VoinpProviders/ OpenAI 互換クライアント                     deps: VoinpNet, VoinpCore
  VoinpUIKit/     メニューバー, HUD, 設定   deps: VoinpEngine     ← VoinpNet なし

Products:
  .executable("voinp",         targets: ["voinp"])
      voinp/main.swift          deps: VoinpUIKit, VoinpProviders, VoinpNet
  .executable("voinp-offline", targets: ["voinp-offline"])
      voinp-offline/main.swift  deps: VoinpUIKit のみ
```

`voinp-offline` は**ネットワークリクエストを行えない**。
ポリシーとしてではなく、**コードが存在しない**から。

仮に誰も `voinp-offline` をインストールしなくても、
**これがコンパイルし続けることが本体ビルドの強制機構になる。**
誰かが `VoinpEngine` に `URLSession` を書いても offline はビルドできてしまうが、
`VoinpNet` への依存を足した瞬間に **CI が落ちる。**

**SPM のターゲット依存が最初の構造的な防衛線であり、タダである。**
ターゲットグラフが宣言した許可リストと一致することを CI で assert する。

## D.2 チョークポイント

コードベース全体で `URLSession` は `VoinpNet` の中の 1 箇所だけ。

- SwiftLint `custom_rules`: `URLSession\(|NWConnection\(|CFSocket|getaddrinfo|NSURLConnection`
  に一致、`excluded: Sources/VoinpNet/.*`
- CI で同じ grep を二重にかける (SwiftLint の設定自体は編集できてしまうため)
- `Package.resolved` が空であること ([D.6](#d6-最も検証しやすい主張-サードパーティ依存ゼロ))

README では、**どれが強制 (D.1、依存数) でどれがツールで確認している規約 (D.2) か**を
正直に書き分ける。

## D.3 `EgressGate` — 実行時ポリシー

```swift
public enum EgressClass: Int, Sendable, Comparable, Codable {
    case loopback = 0         // 127.0.0.0/8, ::1
    case privateNetwork = 1   // RFC1918, fc00::/7, fe80::/10, *.local, 裸のホスト名
    case publicInternet = 2
}

public enum EgressPurpose: String, Sendable, Codable {
    case modelDiscovery, refine, transcribe, updateCheck
}

public struct EgressRequest: Sendable, Codable {
    public let purpose: EgressPurpose
    public let providerID: ProviderID
    public let url: URL
    public let method: String
    public let headers: [String: String]            // 秘密は入れない
    public let secretRefs: [String: CredentialRef]  // "Authorization" -> Keychain 参照
    public let body: Data?
    public let timeout: Duration
    public let carriesUserContent: Bool             // true = 音声か書き起こしが body にある
}

public actor EgressGate {
    public init(policy: @Sendable @escaping () async -> EgressPolicySnapshot,
                audit: EgressAuditLog,
                resolver: any HostResolving = SystemResolver())
    public func send(_ request: EgressRequest) async throws -> EgressResponse
}
```

**公開 API に無いもの**に注目: `URLRequest` がない、`URLSession` がない、クロージャがない。
`EgressRequest` / `EgressResponse` は `Codable` な値型である。

つまり step 2 で `VoinpNet` を別プロセス (XPC) に切り出し、
**音声を扱うプロセスからネットワーク権限を剥奪する**移行が、書き直しではなく機械的作業になる。
**チョークポイントは今作り、XPC 形状のシグネチャにしておく。
プロセス分離はクラウド STT が入るとき** (＝音声が出ていくとき) **にやる。**

秘密は `secretRefs` からゲートの**内部で**注入される。
API キーがアプリの一般アドレス空間に `String` として存在せず、
呼び出し側が誤ってログに出すことができない。

## D.4 ポリシーは導出する

```swift
public struct EgressPolicySnapshot: Sendable, Equatable, Codable {
    public let masterAllow: Bool                // privacy.allowNetwork
    public let maxClass: EgressClass            // privacy.allowedEgressClasses
    public let allowedHosts: Set<HostPattern>   // 設定済みエンドポイントから導出
    public let allowedPurposes: Set<EgressPurpose>

    public static let denyAll = EgressPolicySnapshot(
        masterAllow: false, maxClass: .loopback,
        allowedHosts: [], allowedPurposes: [])
}
```

**`allowedHosts` はユーザーが埋めた設定フィールドから計算する。手で保守しない。**
`refinement.openaiCompatible.baseURL.host` がちょうど 1 エントリを生む。
設定の目に見えるフィールドを変えずに送信先を追加することができず、
プライバシー画面は `allowedHosts` をそのまま描画する。
**UI と強制が同じ値を読んでいる**ことが、信用できる理由である。

### `send()` の判定順

1. `masterAllow == false` → 拒否。
   **設定のパースに失敗したら `.denyAll`。fail closed。この 1 行がこの章で最も重要。**
2. ホストが `allowedHosts` にない → 拒否
3. **ホストを解決し、返った全アドレスを分類し、`maxClass` 以下であることを全部に要求する。**
   「いずれか」ではなく「すべて」。`127.0.0.1` と公開 IP の両方に解決されるホスト名は拒否。
   ホスト名の文字列ではなく**解決後のアドレス**で分類するのはこのため
   (`http://my-llm.local:11434` はローカルに見えるが、そうとは限らない)
4. purpose の検査。`carriesUserContent` 付きの `.transcribe` は、
   設定中の STT プロバイダが実際にネットワークプロバイダであることを要求する
   (音声を LLM エンドポイントに送ってしまうバグを防ぐ)
5. スキーム: `http` は解決クラスが `.privateNetwork` 以下のときのみ。`https` は常に可
6. **リダイレクトを全拒否。**
   `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)` で
   `completionHandler(nil)` を返しエラーにする。
   **リダイレクトはレビューされていない送信先の変更**であり、黙って追従してはいけない
7. **プロキシを送信前に判定する (社用 Mac で多くのアプリが間違える点)。**

   システム設定や PAC で HTTP プロキシが設定されていると、**実際の TCP 相手はプロキシ**である。
   宛先が `127.0.0.1` でも、公開プロキシが適用されれば書き起こしは社外に出る。
   **分類・表示・記録だけでは足りない。許可判定そのものに含める。**

   ```swift
   let proxies = CFNetworkCopyProxiesForURL(url, systemProxySettings)
   switch resolveProxyChain(proxies) {
   case .direct:
       break                                   // 手順 3 の宛先分類のみで判断してよい

   case .proxied(let proxyHosts):
       // プロキシ自身を解決・分類し、宛先と同じ基準を課す
       let proxyClass = try await classifyAll(proxyHosts)
       guard proxyClass <= policy.maxClass else {
           throw EgressDenied.proxyExceedsPolicy(proxyClass)
       }
       // さらに: 宛先が loopback なのにプロキシ経由になる構成は異常
       guard !(destinationClass == .loopback && proxyClass > .loopback) else {
           throw EgressDenied.loopbackDestinationWouldLeaveViaProxy
       }

   case .undeterminable:
       // PAC スクリプトの評価に失敗した / 結果が解釈できない
       throw EgressDenied.proxyChainUnknown      // fail closed
   }
   ```

   **経路を確定できない場合は拒否する** (`.undeterminable`)。
   PAC (`kCFProxyTypeAutoConfigurationURL`) は URL ごとに結果が変わりうるうえ、
   評価にネットワークアクセスが要ることすらある。
   「たぶん直結だろう」で送るのは、この章の他のどの規則よりも危うい。

   実効クラスは **`max(宛先クラス, プロキシクラス)`** として
   `PrivacyPosture` と監査記録の双方に反映する
   (`Destination.viaProxy` はこのために存在する)。

   macOS は既定で `127.0.0.1` をプロキシ対象外にするが、
   **除外リストはユーザーが変更できる**ので、既定に依存せず毎回問い合わせる。

   > 手順 8 の事後検証はこの判定を置き換えない。
   > 事後検証は「バイトが出た後に気づく」仕組みであり、**送信前の拒否がある前提の保険**である。
8. **事後検証。** `urlSession(_:task:didFinishCollecting:)` で
   `metrics.transactionMetrics.last?.remoteAddress` を読み、分類し、
   `maxClass` を超えていたら**違反**として記録し、そのエンドポイントを隔離し、
   目立つ UI 警告を出す。
   これは DNS ベースの事前分類が TOCTOU であることの正直な認め方である —
   バイトは既に出ている。できるのは、ユーザーに必ず伝わることと、二度と起きないようにすることだけ

### 保存前のホストをどう探索するか — 許可リストの鶏卵問題

`allowedHosts` は**保存済み**の設定から導出される。
ところがモデル探索 ([03](03-refinement.md)) は、ユーザーが設定画面に URL を
打ち込んだ直後、**まだ保存していない**段階で走る。
素直に実装すると、新しいエンドポイントを設定しようとした瞬間に手順 2 で拒否され、
**モデル一覧が永久に取れない。**

導出方式を崩さずに解くため、`EgressPolicySnapshot` に候補を 1 つだけ持たせる:

```swift
public struct EgressPolicySnapshot {
    // ...既存のフィールド
    /// 設定画面で「接続」を押した直後だけ入る、ただ 1 つの候補ホスト。
    public let probeCandidate: ProbeCandidate?
}

public struct ProbeCandidate: Sendable, Equatable {
    public let host: HostPattern
    public let port: Int
    public let expiresAt: ContinuousClock.Instant   // 発行から 60 秒
}
```

候補が手順 2 を通過する条件は**すべて**満たすこと:

| 条件 | 理由 |
|---|---|
| `purpose == .modelDiscovery` のみ | 校正や書き起こしには絶対に使わせない |
| `carriesUserContent == false` | 候補ホストにユーザーの発話を送ることはありえない |
| **ユーザーの明示操作で発行された** | 設定画面の「接続」ボタン。設定ファイルの外部編集や起動時には発行しない |
| 60 秒で失効、かつ同時に 1 つだけ | 画面を開きっぱなしにしても残り続けない |
| `masterAllow` と `maxClass` は**通常どおり適用** | 候補だからといってクラス制限は緩めない |

つまり候補は**ホスト許可リストだけを一時的に迂回する**のであって、
マスタースイッチも egress クラス制限もプロキシ判定も素通りしない。

探索が成功して**ユーザーが設定を保存したときに初めて**、
そのホストが `allowedHosts` に導出として載る。
保存しなければ候補は失効し、何も残らない。

UI にもそう出す:
「接続テスト中: `127.0.0.1:1234` — この接続先は保存するまで許可されません」。

> なぜ「入力中は何でも許可」にしないか。
> 設定画面を開いているだけで任意ホストへ送れる状態を作ると、
> 設定ファイルを書き換えられる攻撃者に探索経路を渡すことになる。
> **明示操作・単一・短寿命・用途限定**の 4 つが揃って初めて、導出方式の性質が保たれる。

### DNS 自体が漏らす

`my-llm.internal` を解決した時点で、その DNS サーバに
「この Mac は LLM を探している」と伝わっている。
**真にゼロ egress なのは、リテラル IP の loopback だけ。**
下の姿勢レベルを区別しているのは、まさにこの精度を保つためである。

## D.5 PrivacyPosture — 到達範囲と運用主体を分ける

### 混同してはいけない 2 つの軸

| 軸 | 例 | 機械的に判定できるか | 用途 |
|---|---|---|---|
| **到達範囲** (`EgressClass`) | loopback / 社内 LAN / インターネット経由 | **できる**（解決後アドレスを分類） | **強制**。これだけが許可を決める |
| **運用主体** (`OperatorKind`) | 自社運用 / 外部ベンダー | **できない**（ユーザーの申告） | **表示のみ**。許可を広げない |

この 2 つは独立している。**セルフホストの LLM は loopback とは限らない。**

| 構成 | 到達範囲 | 運用主体 |
|---|---|---|
| `http://127.0.0.1:1234/v1` (LM Studio) | `loopback` | selfHosted |
| `https://10.1.2.3/v1` (社内 LAN / VPN) | `privateNetwork` | selfHosted |
| **`https://llm.example.co.jp/v1` (社内サーバ)** | **`publicInternet`** | **selfHosted** |
| `https://api.openai.com/v1` | `publicInternet` | vendor |

3 行目が要点である。**自社運用でも、公開 DNS 名の HTTPS なら到達範囲はインターネット経由**になる。
到達範囲を甘くしてはいけないが、表示まで `api.openai.com` と同じにするのは実態を誤る。

```swift
public struct PrivacyPosture: Equatable, Sendable {
    /// メニューバーのアイコンはこれで決める。**検証可能な到達範囲のみ**に基づく。
    public enum Level: Int, Comparable, Sendable {
        case offline = 0        // 到達できる送信先がない
        case loopbackOnly = 1   // この Mac の中だけ
        case localNetwork = 2   // Mac の外に出るが LAN 内
        case external = 3       // この Mac とネットワークの外へ出る
        case misconfigured = 4  // 設定エラー。通信を停止している
    }

    /// 誰が運用している先か。**ユーザーの申告であり、アプリは検証できない。**
    public enum OperatorKind: String, Codable, Sendable {
        case selfHosted, vendor, unknown
    }

    public struct Destination: Equatable, Sendable {
        public let dataKind: DataKind          // .audio | .transcript | .refinedText
        public let host: String
        public let port: Int
        public let reach: EgressClass          // 検証可能
        public let operatorKind: OperatorKind  // 申告。表示のみ
        public let providerID: String
        public let viaProxy: String?
    }

    public let level: Level
    public let destinations: [Destination]

    /// 旗印そのもの。整形テキストの送信先が増えてもここは false のままでなければならない。
    public var audioLeavesMachine: Bool {
        destinations.contains { $0.dataKind == .audio && $0.reach > .loopback }
    }

    /// 設定の純粋関数。I/O なし。完全にユニットテスト可能。
    public static func evaluate(_ settings: Settings, hasConfigError: Bool,
                                reachResolver: (String) -> EgressClass) -> PrivacyPosture
}
```

### 申告は許可も表示レベルも緩めない

これが設計上の最重要ルールである。

- `EgressGate` は `operatorKind` を**参照しない**。許可は `allowedEgressClasses` だけで決まる
- **アイコンのレベルも到達範囲だけで決まる。** `api.openai.com` を `self-hosted` と
  書いても、バッジは `.external` のまま

申告で許可が広がると、**設定ファイルを書き換えられる攻撃者に送信経路を渡す**ことになる。
`PrivacyPostureTests` の「ベンダーを self-hosted と申告してもアイコンは external のまま」が
これを固定している。

申告が変えてよいのは**文言だけ**である:

```
外部へ送信 — 整形テキスト → llm.example.co.jp（自社運用と設定）
外部へ送信 — 整形テキスト → api.openai.com（外部サービス）
```

「と設定」という語尾は意図的で、**アプリが検証した事実ではなく設定値である**ことを示す。

### macOS 側の挙動との対応

- `127.0.0.1` への接続はローカルネットワーク権限のプロンプトを**出さない**
- `10.x.x.x` / `192.168.x.x` への接続は**出す**（`NSLocalNetworkUsageDescription` が要る）
- 公開 DNS 名への HTTPS は通常の外向き通信で、特別な権限は不要

### DNS 自体が漏らす

`llm.example.co.jp` を解決した時点で、その DNS サーバに
「この Mac は LLM を探している」と伝わっている。
**真にゼロ egress なのは、リテラル IP の loopback だけ。**
姿勢レベルを分けているのは、この精度を保つためである。

### ゴールデンテスト — 旗印を CI の失敗にする

```swift
@Test("既定設定はオフライン。送信先ゼロ")
@Test("設定エラーなら通信を停止した状態になる")
@Test("到達範囲の上限を超える設定は送信先として現れない")
@Test("ベンダーを self-hosted と申告してもアイコンは external のまま")
@Test("整形テキストの送信先が外部でも、音声は Mac から出ない")
```

実装は `Tests/VoinpNetTests/PrivacyPostureTests.swift`。

## D.6 最も検証しやすい主張: サードパーティ依存ゼロ

過小評価されがちだが、**どんな実行時ゲートより強い**。

**`Package.resolved` に何も入っていないこと。**
Sentry も Sparkle も Alamofire も分析 SDK も Keychain ラッパーも入れない。CI で assert する。

これがあって初めて「何も出ていない」と真顔で言える。
デスクトップアプリのプライバシー事故の多くは、
アプリ自身のコードではなく**推移的依存が勝手に通信する**ことで起きる。
また、セキュリティレビュー担当者が**1 つのターゲットを読むだけで
egress の全表面を監査できる**。

## D.7 検証レシピ

`make verify` として提供し、この節にも載せる。同僚やセキュリティ担当が自分で確かめられること。

```sh
# 1. 付与されている entitlement を見る (サンドボックスなし、network.client なし)
codesign -d --entitlements - ~/Applications/Voinp.app

# 2. リンクしているライブラリを見る
otool -L ~/Applications/Voinp.app/Contents/MacOS/voinp

# 3. オフライン版にネットワークコードが無いことを見る
#    注意: nm -u (未定義シンボル) では判定できない。SwiftPM は静的リンクするため
#    通常版でも 0 件になる。定義シンボル (-U) を数えること。
nm -U .build/debug/voinp-offline | grep -cE '8VoinpNet|VoinpProviders'   # => 0
nm -U .build/debug/voinp         | grep -cE '8VoinpNet|VoinpProviders'   # => 178 (対照)

# 4. 既定設定で起動し、開いているソケットを見る —— 何も出ないこと
lsof -i -a -p "$(pgrep -x voinp)"

# 5. 依存が空であること
cat Package.resolved
```

この一式は `./scripts/verify-privacy.sh`（`make verify` から呼ばれる）に実装済みで、
**対照群が 0 件でないことまで確認する**（検証コマンド自体が機能しなくなる事故を防ぐため）。

**4 番目がこの機能を売る実演である。**
「Little Snitch を開いて、5 分喋って、接続が 1 本も出ないことを見てください。」
**その実演が常に成立するようにプロダクトを作る。**

## D.8 UI が示すべきこと

### メニューバーのアイコン = `PrivacyPosture.Level`、常時表示

| Level（到達範囲のみで決まる） | アイコン | メニューの見出し（運用主体の申告を文言に反映） |
|---|---|---|
| `.offline` | `mic` モノクロ | 完全ローカル — 送信先なし |
| `.loopbackOnly` | `mic.fill` + `house` バッジ | この Mac 内のみ — 整形テキスト → 127.0.0.1:1234 |
| `.localNetwork` | 琥珀色バッジ | 社内ネットワーク — 整形テキスト → 10.1.2.3:443（自社運用と設定） |
| `.external` | `globe` 着色 | 外部へ送信 — 整形テキスト → llm.example.co.jp（自社運用と設定） |
| `.external` | `globe` 着色 | 外部へ送信 — 整形テキスト → api.openai.com（外部サービス） |
| `.misconfigured` | `exclamationmark.triangle` | 設定エラー — 通信を停止しています |

最後から 2 行目と 3 行目は**同じアイコン**である。
自社運用の申告で見た目を優しくしない、というのがこの表の主張。

加えて **リクエスト実行中はバッジをアニメーションさせる。**
ユーザーが外向き通信の 1 本 1 本を*目で見られる*ようにする。
5 行の機能だが、信頼への効果が大きい。

### 設定 → プライバシー画面

1. `destinations` から描く姿勢テーブル: **「何が / どこへ / どの経路で」**。
   行は 音声 / 書き起こし / 整形テキスト。それぞれ「送信しません」か、
   host:port + クラスバッジ + **どの設定フィールドが原因か**
2. 導出された許可リストを**読み取り専用**で表示。
   「この値は `refinement.openaiCompatible.baseURL` から自動導出されています」と注記
3. マスターキルスイッチ:「ネットワークを完全に遮断」→ `privacy.allowNetwork = false`。
   アイコンが即座にロックされる
4. 監査ログビューア (CSV エクスポート付き)
5. 静的な「このアプリが行わないこと」リスト。**製品内に書くこと自体が製品の一部である**:
   - 利用統計・テレメトリの送信はしません
   - クラッシュレポートの自動送信はしません
   - 起動時のアップデート確認はしません
   - 音声をディスクに書き込みません
   - 書き起こしを既定では保存しません

## D.9 やらないこと

- **テレメトリなし。** 「匿名の利用回数」も含めて。例外なし、オプトアウトという形も作らない
- **クラッシュレポート SDK なし。**
  macOS 自身の `~/Library/Logs/DiagnosticReports/*.ips` を使い、
  社内チケットに添付してもらう。Sentry / Crashlytics はスタックフレームと
  ときにブレッドクラム文字列を機外に送る
- **自動アップデート確認なし。**
  `privacy.updateCheck` は `"manual"` か `"never"` のみを受け付ける。`"auto"` は存在しない。
  手動の確認でも IP とバージョンが相手に伝わるので、通常の egress イベントとして
  監査ログに載りインジケータが光る。
  **より良いのは、アプリ内更新機構を作らないこと** — 配布は各自の `make install` ([07](07-build.md))
- **音声をディスクに書かない。**
  経路は `AVAudioEngine` tap → `AVAudioConverter` → `AudioChunk` → プロバイダ → 破棄。
  デバッグ用の音声保存はセッションごとの明示的トグルを要求し、
  **有効な間はメニューバーのアイコンを目に見えて変える。**
  設定に `debugSaveAudio: true` を書いて忘れられる形にはしない
- **書き起こし履歴は既定オフ** (`history.keepLastTranscripts: 0`)。
  履歴ファイルは「その席で話された全内容の平文記録」である。
  足すとしてもオプトイン・上限付き・プライバシー画面に表示
- **`OSLog` でユーザーテキストを `privacy: .public` で出さない。**
  専用サブシステム `com.naotama2002.voinp` を使い、
  ユーザーテキストを含みうる補間はすべて `\(text, privacy: .private)` にする。
  `os.log` の既定は `.public` なので、**書き起こしが unified log に入り
  任意の管理ツールから読める**ことになる。**全 `Logger` 呼び出し箇所を監査する。**
  約束を丸ごと破る現実的な経路の 1 つ
- **ペーストボードは egress 経路である。**
  Universal Clipboard がディクテーションしたテキストを Apple のサーバ経由で
  ユーザーの iPhone に運びうる。**誰も監査していない経路で旗印が静かに破れる。**
  - `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType` を付ける
  - プライバシー画面に
    「クリップボード経由 — Universal Clipboard が有効な場合、
    テキストが他のデバイスに同期される可能性があります」と出す
  - `insertion.strategy = "keystroke"` でペーストボードを一切使わない経路を提供する
  - **未決: 実際の Handoff の挙動を実装前に実測する。**
    クリップボードマネージャはこの規約を尊重するが、
    Apple の Universal Clipboard の挙動は契約として文書化されていない

## D.10 監査ログ

```swift
public struct EgressRecord: Sendable, Codable {
    public let timestamp: Date
    public let purpose: EgressPurpose
    public let providerID: ProviderID
    public let host: String
    public let port: Int
    public let requestedClass: EgressClass
    public let actualPeerClass: EgressClass?     // URLSessionTaskMetrics.remoteAddress から
    public let viaProxy: String?
    public let bytesOut: Int
    public let bytesIn: Int
    public let durationMs: Int
    public let outcome: Outcome                  // .allowed(status:) | .denied(reason) | .violation
    // ユーザーの内容を保持できるフィールドを意図的に持たない。
}

public actor EgressAuditLog {
    public func record(_ r: EgressRecord) async
    public var recent: [EgressRecord] { get }    // リングバッファ、既定 500
    public func exportCSV() -> Data
}
```

**ペイロード、URL のクエリ文字列、ヘッダを絶対にログしない。**
これを**構造的に真にする** — `EgressRecord` にテキストを入れられるフィールドがないので、
不注意な `log(request)` が漏洩としてコンパイルされない。

ディスク: `~/Library/Application Support/voinp/logs/egress.jsonl`、1 MB × 3 でローテート。
**既定オン** — 社内ツールとしてセキュリティ担当が求めるものであり、
構造上ユーザーの内容を含まない。存在することをプライバシー画面に書き、トグルも置く。

## 設定

`config.json` の該当部分のみ。全体像は [07](07-build.md#全体像) を参照。

```jsonc
"privacy": {
  "allowNetwork": false,                   // マスタースイッチ。false なら全送信を拒否
  "allowedEgressClasses": ["loopback"],    // "loopback" | "privateNetwork" | "publicInternet"
  "extraAllowlistHosts": [],               // 通常は空
  "auditLog": { "enabled": true, "toDisk": true, "maxEntries": 500 },
  "updateCheck": "never"                   // "never" | "manual"。"auto" は存在しない
}
```

**既定は `allowNetwork: false` かつ `refinement.enabled: false`。**
出荷時の設定は `PrivacyPosture.Level.offline` になる。

## Info.plist

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key><true/>   <!-- loopback / RFC1918 / *.local への平文 http -->
</dict>
<!-- NSAllowsArbitraryLoads は絶対に書かない -->

<key>NSLocalNetworkUsageDescription</key>
<string>社内ネットワーク上のローカル LLM に接続するために使用します。設定でローカルネットワークを有効にした場合のみ通信します。</string>

<key>NSMicrophoneUsageDescription</key>
<string>音声入力のためにマイクを使用します。音声はこの Mac 上で処理され、保存されません。</string>
```

## step 2 で再検討すること

クラウド STT を入れる = **音声が Mac の外に出る**。そのときに:

- `VoinpNet` を XPC サービスに切り出し、音声を扱うプロセスからネットワーク権限を剥奪する。
  `EgressRequest` / `EgressResponse` が `Codable` 値型なのは、この移行のため ([D.3](#d3-egressgate--実行時ポリシー))
- `PrivacyPosture` に `.audio` の destination が現れ、アイコンが `.cloud` になる
- 「音声を送る」ことについて、初回に明示的な確認ダイアログを出す
