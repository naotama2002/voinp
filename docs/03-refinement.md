# 03. LLM 校正

## 位置づけ

書き起こしテキストを LLM に通して、フィラー除去・句読点整形・明らかな誤認識の修正を行う。

- **既定はオフ。** オンにしても送るのは *テキスト* であり *音声* ではない
- step 1 の想定は **OpenAI 互換 API のセルフホスト LLM**

### 「セルフホスト」は loopback とは限らない

用語を分けておく。混同すると設計を誤る（実際に一度誤った）。

| 語 | 意味 |
|---|---|
| **ローカル** | `127.0.0.1` / `::1`。この Mac の中 |
| **セルフホスト** | 自社・自分で運用している。**置き場所は問わない** |

step 1 で想定する接続先は 3 形態すべて:

| 構成 | 例 | 到達範囲 |
|---|---|---|
| 手元の Mac | `http://127.0.0.1:1234/v1` (LM Studio / Ollama) | `loopback` |
| 社内 LAN / VPN | `https://10.1.2.3/v1` | `privateNetwork` |
| 社内サーバ | `https://llm.example.co.jp/v1` (vLLM 等) | **`publicInternet`** |

3 行目は**自社運用でも到達範囲はインターネット経由**になる。
プライバシー姿勢の表示と送信ゲートはこの区別を保つ（[06](06-privacy.md)）。

設定にはどちらの軸も持つ:

```jsonc
"openaiCompatible": {
  "baseURL": "https://llm.example.co.jp/v1",
  "operatorKind": "self-hosted"   // 表示専用の申告。送信許可は広げない
}
```
- **校正の失敗でユーザーの発話を失わない。** 何が起きても生原稿を挿入する

プロンプトの中身は [04](04-prompts.md) を参照。ここでは通信と制御の話をする。

### `FoundationModels` について

macOS 26 には `FoundationModels.framework` があり、Apple Intelligence のオンデバイス LLM を
`SystemLanguageModel` / `LanguageModelSession` で呼べる。
**設定ゼロ・ネットワークゼロ**で動くため、旗印との相性は最も良い。

#### 利用可否は OS バージョンだけでは決まらない

macOS 26 は下限条件にすぎない。`SystemLanguageModel.availability` は実行時に評価され、
利用不可の理由は 3 つに分かれる (SDK で確認):

```swift
public enum UnavailableReason {
    case deviceNotEligible            // ハードウェアが非対応 (Intel Mac 等)
    case appleIntelligenceNotEnabled  // ユーザーが有効化していない
    case modelNotReady                // 資産をダウンロード中 / 未取得
}
```

つまり **同じ macOS 26 でも、マシンとユーザー設定によって使えたり使えなかったりする。**
しかも `modelNotReady` は**実行中に解消されうる** (ダウンロードが完了すれば `.available` になる)。
起動時に一度だけ判定してキャッシュしてはいけない。

#### この開発機での実測

```
FoundationModels: UNAVAILABLE -> appleIntelligenceNotEnabled
```

理由を切り分けると:

| 項目 | 実測 |
|---|---|
| チップ | Apple M4 Pro / 48 GB → **ハードウェアは対応** (`deviceNotEligible` ではない) |
| `com.apple.CloudSubscriptionFeatures.optIn` | `opted_out_buddy = 1` → **初期設定でオプトアウトした** |
| `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels` | 空 → モデル未取得 |
| 関連デーモン | `generativeexperiencesd` / `intelligenceplatformd` は稼働中 |
| ロケール | `ja_JP` |

**ハードウェアの制限ではなく、ユーザー設定である。**
システム設定で Apple Intelligence を有効にすれば、この機でも `.available` になる。

#### 設計上の扱い

社内で配ると、**同僚ごとに使えたり使えなかったりする**ことになる。
だから固定の前提にはできない一方、切り捨てるのも惜しい:

> **`apple.foundationmodels` は、校正を有効にしたまま
> `PrivacyPosture` を `.offline` に保てる唯一の選択肢である** ([06](06-privacy.md))。
> ローカル LLM (`127.0.0.1`) ですらプロセス外に出るが、これは出ない。

したがって:

- **step 1 の主経路は `openai-compatible`** のままとする
  (誰の環境でも動き、モデルを選べ、日本語の語調の扱いも上)
- `apple.foundationmodels` は `LLMClient` の実装として**同時に用意する**。
  `availability` が `.available` のときだけ設定画面の選択肢に出す
- **判定は毎回行う。** 起動時にキャッシュしない (`modelNotReady` は解消されうる)
- 利用不可のときは理由ごとに違う案内を出す:

| 理由 | 設定画面での案内 |
|---|---|
| `deviceNotEligible` | この Mac では利用できません (Apple Silicon が必要) |
| `appleIntelligenceNotEnabled` | システム設定で Apple Intelligence を有効にすると使えます (リンク付き) |
| `modelNotReady` | モデルを準備中です。しばらくお待ちください |

これは `SetupRequirement` の枠組みにそのまま乗る ([02](02-transcription.md))。

#### 実装上の注意

- `SystemLanguageModel(guardrails: .permissiveContentTransformations)` を使う。
  「この文を書き換えろ、内容に説教するな」という用途のために存在する指定である。
  既定の guardrails だと、ディクテーション内容によっては校正を拒否される
- `LanguageModelSession` は `final class` で **`Sendable` ではない。**
  `respond(to:options:)` は `nonisolated(nonsending)` で呼び出し側の isolation を継承するので、
  **refiner actor の格納プロパティとして持てば素直に動く** ([01](01-architecture.md))
- **未検証:** 3B 級のオンデバイスモデルが日本語の敬体/常体の統一をどの程度こなせるか。
  Apple Intelligence を有効にした機で実測してから、プリセットごとの推奨を決める

## 2 層に分ける

**トランスポート** (ワイヤプロトコルごと) と **ポリシー** (1 実装を共有) を分離する。

```swift
// ── VoinpLLM ────────────────────────────────────────────────────────
public protocol LLMClient: Sendable {
    static var descriptor: ProviderDescriptor { get }
    func readiness() async -> Readiness
    func listModels() async throws -> [ModelInfo]
    func complete(_ request: CompletionRequest) async throws -> CompletionResult
}

public struct CompletionRequest: Sendable {
    public var model: String
    public var system: String
    public var user: String
    public var temperature: Double?
    public var maxOutputTokens: Int?
    public var stop: [String]
    public var timeout: Duration
    public var extraBody: [String: JSONValue]   // enable_thinking / reasoning_effort 等
}

public struct CompletionResult: Sendable {
    public var text: String
    public var finishReason: FinishReason       // .stop | .length | .contentFilter | .other
    public var modelEcho: String?
    public var latency: Duration
}

public struct ModelInfo: Sendable, Identifiable, Hashable {
    public let id: String              // model パラメータにそのまま入れる値
    public let displayName: String     // llama.cpp はファイルパスを返すので別に持つ
    public let contextWindow: Int?
    public let hints: Set<ModelHint>   // .likelyReasoning など
}
```

### なぜ `[Message]` ではなく `system: String` + `user: String` か

校正タスクは**常に** system 1 ターン + user 1 ターンで固定である。
汎用のメッセージ配列にすると、会話履歴・few-shot・画面コンテキストを足したくなる。
**そのどれもが「外に出るテキストが増える」ことを意味する。**
型を絞ることで機能を絞っている。

副次的な利点として、将来のプロバイダ追加が小さくなる:

| プロバイダ | マッピング |
|---|---|
| Anthropic | `system` → トップレベル `system`、`user` → `messages: [{role:"user"}]` |
| Gemini | `system` → `systemInstruction`、`user` → `contents[0].parts[0].text` |

**それぞれ約 120 行**。JSON ボディを組んで 1 フィールドをデコードしてエラーを写すだけ。

### ポリシー層はプロトコルにしない

実装が 1 つしかないものをプロトコルにする理由はない。

```swift
public struct TextRefiner: Sendable {
    public init(client: any LLMClient,
                prompts: PromptLibrary,
                guard: RefinementGuard,
                policy: RefinementPolicy,
                clock: any Clock<Duration>)

    /// throw しない。必ず挿入可能な何かを返す。
    public func refine(transcript: String,
                       presetID: PresetID,
                       adHoc: String?,
                       locale: Locale) async -> RefinementOutcome
}

public struct RefinementOutcome: Sendable {
    public let text: String              // 挿入するテキスト
    public let source: Source            // .refined | .rawFallback(FallbackReason)
    public let latency: Duration
}

public enum FallbackReason: Sendable, Equatable {
    case disabled, noProvider, notReady
    case blockedByPrivacyGate
    case timedOut(Duration)
    case transport(String)
    case guardRejected(GuardRejection)
    case emptyResult
}
```

**`refine` が `throws` でないのは設計である。**
「ユーザーが喋ったのに何も挿入されない」コードパスを型システムで書けなくする。

## モデル探索 — ベース URL を入れたらモデル一覧が出る

```swift
public enum EndpointProbe {
    public static func discover(rawInput: String,
                                apiKey: String?,
                                via gate: EgressGate) async -> Result<Discovery, ModelDiscoveryError>
}

public struct Discovery: Sendable {
    public let normalizedBaseURL: URL      // config に保存するのはこちら。ユーザーの生入力ではない
    public let models: [ModelInfo]
    public let detectedServer: ServerFlavor?
    public let egressClass: EgressClass
}
```

### 正規化の段取り

先頭から試し、最初に 2xx + パース可能な JSON を返したものを採用する。

1. 前後の空白と末尾 `/` を削る
2. スキームがなければ補う。
   ホストが loopback / RFC1918 / `.local` / 裸のホスト名なら `http://`、
   **それ以外は `https://`**。公開ホストを黙って平文に落とさない
3. 候補:
   - 入力が既に `/models` で終わっていればそれをそのまま最初に試す
   - `{base}/models` — ユーザーが `…:1234/v1` を貼った場合に正しい
   - `{base}/v1/models` — ユーザーが `…:1234` を貼った場合に正しい
4. 採用した候補から `/models` を除いたものを `normalizedBaseURL` として保存し、
   **UI にそのまま表示して確認させる** —「使用する URL: http://127.0.0.1:1234/v1」。
   黙って書き換えない
5. **`localhost` → `127.0.0.1` のリトライ。**
   `localhost` が connection refused なら `127.0.0.1` で再試行する。
   `localhost` は `::1` に先に解決されることが多く、これらのサーバは IPv4 のみに
   bind していることが多い。**10 行で「動かない」報告の最多ケースが消える。**

リクエストは `GET`、`Accept: application/json`、API キーがある場合のみ
`Authorization: Bearer …`、**タイムアウト 5 秒、リトライ 0 回** (ユーザーが見ている)、
リダイレクトは拒否 ([06](06-privacy.md))。

**送信ゲートとの関係。** 探索する時点では、そのホストはまだ設定に保存されておらず
`allowedHosts` に載っていない。素直に実装すると自分のゲートに阻まれて
モデル一覧が永久に取れないので、
**`purpose: .modelDiscovery` 限定・`carriesUserContent: false`・ユーザーの明示操作で発行・
60 秒で失効する候補ホスト**という仕組みで解く。
`masterAllow` と egress クラス制限とプロキシ判定は通常どおり適用される。
詳細は [06](06-privacy.md#保存前のホストをどう探索するか--許可リストの鶏卵問題) を参照。

### レスポンスのパースは寛容に

```
{"object":"list","data":[{"id":"…"}]}     ← OpenAI 形 (LM Studio / Ollama /v1 / llama.cpp / vLLM)
[{"id":"…"}]                               ← 裸の配列 (一部のプロキシ)
{"models":[{"name":"…"}]}                  ← Ollama /api/tags (エラーメッセージ改善用の探り)
```

未知のキーは無視し、`id` / `name` が非空であることだけ要求する。

### サーバごとの差異

| サーバ | 既定ポート | 注意 |
|---|---|---|
| **LM Studio** | 1234 | `/v1/models` は OpenAI 形。**ダウンロード済み**モデルを列挙し、最初のリクエストで JIT ロードする → **初回の校正が 10〜30 秒かかる**。ピッカーで警告する |
| **Ollama** | 11434 | `/v1/models` が OpenAI 互換シムとして動く。`id` は `"qwen3:8b"` のタグ形式。`/api/tags` はエラーメッセージを良くするためだけに叩く |
| **llama.cpp server** | 8080 | `/v1/models` は **1 件だけ**返し、`id` が gguf のファイルパス。表示は `lastPathComponent`、送信は `id` のまま (サーバは `model` を無視する) |
| **vLLM** | 8000 | `--api-key` 付きで起動されていることが多く、**loopback なのに 401** を返して驚かれる。`id` は HF のリポジトリパス |

### エラー分類とユーザー向けメッセージ

ここが UX の勝負どころ。以下をハードコードすると実際の失敗の 9 割を拾える。

```swift
public enum ModelDiscoveryError: Error, Sendable {
    case invalidURL
    case blockedByPrivacyGate(EgressClass)
    case connectionRefused(host: String, port: Int)
    case hostNotFound(String)
    case tlsFailure(String)
    case timedOut
    case notFound(triedPaths: [String])
    case unauthorized(hasKey: Bool)
    case notJSON(contentType: String?, snippet: String)
    case emptyModelList
    case server(status: Int, bodySnippet: String)
}
```

| 条件 | メッセージ |
|---|---|
| `connectionRefused` :11434 | Ollama が起動していないようです。`ollama serve` を実行してください |
| `connectionRefused` :1234 | LM Studio の Local Server が起動していません (Developer タブ → Start Server) |
| `notFound` 両パス試行後 | このURLは OpenAI 互換 API ではないようです。`/v1` を含む URL を確認してください |
| `unauthorized(hasKey: false)` かつ loopback | vLLM の `--api-key` が設定されています。API キーを入力してください |
| `notJSON(contentType: "text/html")` | Web UI の URL を入力していませんか？ API サーバーの URL (例: `http://127.0.0.1:1234/v1`) が必要です |
| `emptyModelList` / Ollama | `ollama pull qwen3:8b` などでモデルを取得してください |
| `emptyModelList` / LM Studio | LM Studio でモデルをロードしてください |
| `blockedByPrivacyGate` | プライバシー設定で送信が許可されていません |

加えて**常に「モデル名を直接入力」のテキストフィールドを出す**。
`/models` を実装していない社内ゲートウェイが存在する。

## HTTPS 接続の扱い

社内サーバを HTTPS で立てる構成が対象に入るので、TLS の前提を決めておく。

- **サーバ証明書は公的 CA（Let's Encrypt 等）を前提とする。**
  `URLSession` が標準で検証できるため、アプリ側に証明書まわりの実装は要らない
- **証明書検証を無効化する設定は実装しない。** 「社内だから」という理由で
  検証を切れる口を作ると、その設定は必ず残り続け、
  中間者攻撃に対して書き起こしテキストが無防備になる。
  自己署名証明書を使いたい場合は、**CA を System キーチェーンに入れる**のが正しい手順
  （通常は MDM で配布する）
- **証明書エラーは専用のエラー種別にする。** `tlsFailure` として扱い、
  「サーバ証明書を検証できません。社内 CA を使用している場合は
  System キーチェーンに追加してください」と案内する
- **mTLS クライアント証明書は現時点で未対応。**
  社内ゲートウェイが要求する場合は `URLSessionDelegate` の
  `didReceive challenge` で対応することになるが、step 1 では実装しない

平文 `http` を許すのは `loopback` と `privateNetwork` に対してのみで、
公開ホストへの平文は常に拒否する（[06](06-privacy.md) の判定順 5）。

## ストリーミングはしない

**推奨: 非ストリーミング。SSE は実装しない。**

- 出力は短い 1 段落で、他アプリのテキスト欄に**一括で**挿入される。
  トークンを描画する場所がない。ストリーミングの価値は描画中の体感レイテンシであり、描画しない
- SSE はプロバイダごとにデルタの形が違う
  (`choices[].delta.content` / `content_block_delta` / チャンク化 JSON 配列)。
  **ユーザー利益ゼロでパーサが 3 つ**増える。「小さな追加で済む」設計を壊す
- 進捗表示は HUD の経過時間スピナーで足りる

唯一の反論は「最初のトークンが来たかで『考えている』と『ハングした』を区別できる」だが、
下の 2 段階デッドラインで同じ UX が得られる。

### 勘所: 推論モデルがレイテンシ予算を破壊する

LM Studio 上の `gpt-oss` / Qwen3 (thinking 有効) / DeepSeek-R1 系は、
答えの前に数千トークンの `<think>` ブロックを吐く。対策はどれも安い:

1. ガード実行前に `<think>…</think>` / `<reasoning>…</reasoning>` を除去
   (`refinement.stripThinkTags: true`)
2. `extraBody` を送る。知らないサーバは無害に無視する
   - `{"chat_template_kwargs": {"enable_thinking": false}}` (Qwen3 / vLLM / LM Studio)
   - `{"reasoning_effort": "low"}` (gpt-oss)
3. モデルピッカーで `/(r1|reasoning|think|gpt-oss|qwq)/i` に一致する id に
   `ModelHint.likelyReasoning` を付け、「推論モデルは整形用途には遅すぎる場合があります」と出す

## タイムアウト・リトライ・失敗方針

```swift
public struct RefinementPolicy: Sendable {
    public var softDeadline: Duration      // ローカル 1500 ms / クラウド 3 s
    public var hardDeadline: Duration      // ローカル 4 s    / クラウド 8 s
    public var maxRetries: Int             // 1
    public var disableAfterConsecutiveFailures: Int   // 3
}
```

- **softDeadline**: 見た目だけ。HUD が「整形中…」に変わり、Esc で即スキップできると示す。
  Esc を押したら生原稿を即挿入
- **hardDeadline**: リクエストをキャンセルし生原稿を挿入。
  `Task` グループで `ContinuousClock.sleep` と競争させ、
  合わせて `URLSessionConfiguration.timeoutIntervalForRequest` も設定する
- **リトライは最大 1 回**、かつ**レスポンスのバイトが 1 つも来る前**のトランスポート障害のみ
  (connection refused/reset、DNS 失敗、1 秒未満のタイムアウト)。
  hardDeadline 後は絶対にしない。4xx ではしない。429/503 は `Retry-After ≤ 1s` のときだけ。
  **4 秒の予算の中で 6 秒の LLM 呼び出しをリトライするのは論理的に破綻している。
  ディクテーションツールでは「速く失敗する」が「遅く成功する」に勝つ。**

### URLSession 設定 (すべて意味がある)

```swift
let c = URLSessionConfiguration.ephemeral
c.waitsForConnectivity = false    // 既定 true だと LM Studio が落ちているとき無言でハングする
c.timeoutIntervalForRequest = hardDeadline
c.timeoutIntervalForResource = hardDeadline
c.httpMaximumConnectionsPerHost = 1
c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
c.urlCache = nil                  // レスポンス本文 = 書き起こしテキスト。ディスクに残さない
c.httpCookieStorage = nil
c.httpShouldSetCookies = false
c.httpAdditionalHeaders = ["User-Agent": "voinp/\(version)"]   // 識別情報を入れない
```

`waitsForConnectivity = false` と `urlCache = nil` は特に重要。
前者はハングの原因、後者は書き起こしがディスクキャッシュに残る経路。

### 失敗方針: 必ず生原稿を挿入する

**何も挿入しない、を絶対にやらない。モーダルを出さない。黙って捨てない。**

ユーザーは喋った。その言葉はテキスト欄に着地しなければならない。
校正は*付加価値*であって、たまに文を食うディクテーションツールは
一度も校正しないツールより悪い。

劣化は非モーダルに伝える: HUD に 1.5 秒だけ「整形なしで挿入」バッジを出し、
メニューに直近のエラーを残す。

### サーキットブレーカ

**この節で最も重要な UX 判断。**
校正が 3 回連続で失敗したら、そのセッション中は校正を自動で無効化し、
「整形を一時無効にしました — 再有効化」という項目をメニューに出し続ける。

これがないと、LM Studio を閉じたユーザーは**発話のたびに 4 秒の税金**を払い、
「このアプリは壊れている」と結論づける。

### 採用しない案

「まず生原稿を挿入し、後から選択し直して整形版に置き換える」。
キーストロークを合成しているので技術的には可能だが、**やらない。**
他アプリでの後方選択 + 再入力はユーザー自身のタイピングと競合し、
補completion や自動整形のあるアプリ (Slack / Notion / Xcode) で壊れ、
対象が選択を拒否したときに**他人のドキュメントを静かに破壊する**。

## 設定

`config.json` の該当部分のみ。全体像は [07](07-build.md#全体像) を参照。

```jsonc
"refinement": {
  "enabled": false,                        // 既定オフ
  "provider": "openai-compatible",         // "none" | "openai-compatible" | "apple.foundationmodels"
                                           // step2: "anthropic" | "gemini"
  "defaultPresetID": "clean",
  "softDeadlineMs": 1500,
  "hardDeadlineMs": 4000,
  "maxRetries": 1,
  "disableAfterConsecutiveFailures": 3,
  "temperature": 0.1,
  "maxOutputTokens": 1024,
  "stripThinkTags": true,

  "openaiCompatible": {
    "baseURL": "http://127.0.0.1:1234/v1",  // 正規化後の値
                                            // 例: "https://llm.example.co.jp/v1" も可
    "model": "qwen3-8b-instruct",
    "operatorKind": "self-hosted",          // "self-hosted" | "vendor"
                                            // 表示専用の申告。送信許可は広げない
    "requiresAPIKey": false,                // true なら Keychain から読む
    "extraHeaders": {},                     // Authorization 等は書けない (起動時に拒否)
    "extraBody": {}
  }
}
```

## 資格情報 — Keychain のみ

`config.json` に秘密は一切書かない。

| 属性 | 値 |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `"com.naotama2002.voinp"` — **1 サービス、複数アカウント** |
| `kSecAttrAccount` | `"<providerID>/<field>"` 例: `openai-compatible/apiKey` |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| `kSecAttrSynchronizable` | `false` (明示的に指定する) |
| `kSecUseDataProtectionKeychain` | `true` |

```swift
public struct CredentialRef: Sendable, Hashable, Codable {
    public let account: String          // "openai-compatible/apiKey"
    public static let service = "com.naotama2002.voinp"
}

public protocol CredentialStore: Sendable {
    func read(_ ref: CredentialRef) throws -> String?
    func write(_ value: String, to ref: CredentialRef) throws
    func delete(_ ref: CredentialRef) throws
    func deleteAll() throws
}
```

TypeWhisper (`Services/Cloud/KeychainService.swift`) はサービス名を秘密ごとに変える方式だが、
ここでは変える:

- **1 サービス + アカウントキー**なら「全部消す」が `SecItemDelete` 1 回で済み、
  Keychain Access.app で一覧が読める。同僚にこのアプリを信用してもらう上でこれは効く
- **`ThisDeviceOnly`** で API キーが iCloud Keychain に同期されるのを防ぐ。
  「この Mac から出ない」を謳うアプリが資格情報を Apple に同期させるのは自己矛盾

### `extraHeaders` を守る

ユーザーがトークンを貼りたくなる場所。読み込み時に
`(?i)^(authorization|api-key|x-api-key|x-goog-api-key|token|cookie)$` に一致するキーを拒否し、
`ConfigIssue` を出して Keychain の UI に誘導する。10 行で、平文ファイルに資格情報が
座るのを防げる。

## step 2 で足すもの

```jsonc
// 形は openaiCompatible と同型
"anthropic": { "baseURL": "https://api.anthropic.com", "model": "claude-...",
               "requiresAPIKey": true },
"gemini":    { "baseURL": "https://generativelanguage.googleapis.com",
               "model": "gemini-...", "requiresAPIKey": true }
```

モデル一覧の取得先: Anthropic は `GET /v1/models`、Gemini は `GET /v1beta/models`。
どちらも `EndpointProbe` と同じ枠組みに収まる。

`descriptor.egress` が `.fixedHosts([...])` になり、
`PrivacyPosture` が `.cloud` に変わってメニューバーのアイコンが変わる ([06](06-privacy.md))。

## 勘所: API キーは接続先ホストごとに分ける

固定の口座名 1 つ (`openai-compatible/apiKey`) に保存していた頃、
**接続先を変えると前のサーバー用の API キーが新しいサーバーへ送られていた。**
キー欄を空にして別ホストへ接続テストしても、保存済みのものが付与された。

口座名にホストを含める (`openai-compatible/apiKey@<host>`)。
未登録のホストでは `CredentialStore.read` が nil を返し、
`EgressGate` は Authorization ヘッダを付けずに送る。

さらに `EndpointProbe.discover` から `credential:` 引数を**削除**した。
正規化後のホストから自分で引くので、呼び出し側が取り違えようがない。
「気をつける」ではなく、渡せなくすることで防ぐ。

`CredentialScopeTests` で固定している。

## 勘所: 連続失敗カウンタは発話をまたいで共有する

`disableAfterConsecutiveFailures` は設定にも UI にもあったが機能していなかった。
発話ごとに `TextRefiner` を作り直しており、内部の `FailureCounter` も
毎回 0 に戻っていたため。サーバーが落ちていても一時停止は永久に発動せず、
喋るたびに `hardDeadlineMs` だけ待たされ続けた。

カウンタは `AppModel` が持ち、`TextRefiner` へ注入する。
クライアント自体は接続先を変えられるよう毎回作るが、カウンタは持ち越す。
接続設定 (`settings.refinement`) を変えたら `clear()` する
— 直したのに「連続失敗のため一時停止中」が出続けるのは理不尽なので。

## 勘所: 探索で通った URL をそのまま保存する

接続テストはモデル一覧だけを返し、UI 側が入力文字列に `/v1` を付け直して
保存していた。探索は複数の候補を試すので、`https://host/custom` で疎通できても
保存されるのは `https://host/custom/v1` になり、
**接続テストは成功するのに校正だけ失敗する**という切り分けにくい状態になった。

`ModelDiscoveryResult.success` に確定した `baseURL` を載せ、それを保存する。
画面の入力欄にも書き戻して、テストした対象と保存した対象を一致させる。
