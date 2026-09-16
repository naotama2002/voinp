# 02. 音声取り込みと音声認識

## 前提 (実測値)

このマシン (macOS 26.6.1 / Xcode 26.3 / Swift 6.2.4 / arm64) で確認済み。

```
SpeechTranscriber.isAvailable: true
supportedLocales: de-AT de-CH de-DE en-AU en-CA en-GB en-IE en-IN en-NZ en-SG en-US
                  en-ZA es-CL es-ES es-MX es-US fr-BE fr-CA fr-CH fr-FR it-CH it-IT
                  ja-JP ko-KR pt-BR pt-PT yue-CN zh-CN zh-HK zh-TW
ja match: ja-JP
ja asset status: supported        ← installed ではない。初回 DL フローが必要
bestFormat: 1 ch, 16000 Hz, Int16
AssetInventory.maximumReservedLocales: 5
```

## `DictationTranscriber` を第一候補にする

`Speech.framework` には音声認識モジュールが 2 つある。どちらも macOS 26.0+。

| | `SpeechTranscriber` | `DictationTranscriber` |
|---|---|---|
| `TranscriptionOption` | `.etiquetteReplacements` | **`.punctuation`**, **`.emoji`**, `.etiquetteReplacements` |
| `ContentHint` | なし | `.shortForm` / `.farField` / `.atypicalSpeech` |
| Preset | `.transcription`, `.progressiveTranscription` … | `.phrase`, `.shortDictation`, **`.progressiveShortDictation`**, `.longDictation` … |
| `ReportingOption` | `.volatileResults`, `.fastResults`, `.alternativeTranscriptions` | `.volatileResults`, `.frequentFinalization`, `.alternativeTranscriptions` |

`DictationTranscriber` だけが **`.punctuation`** を持つ。
日本語の句読点 (、。) をエンジン側で補ってくれるなら、LLM 校正の仕事が減り、
**校正オフでも実用になる**。これは旗印にとって重要 — 校正をオフにしても使えるほど、
ネットワークを一切使わない構成が現実的になる。

また `.progressiveShortDictation` は「テキスト欄に一文話し込む」用途に設計されており、
長尺書き起こし向けの `SpeechTranscriber` よりこのアプリに近い。

> **TypeWhisper は `SpeechTranscriber` を使っている**が、あちらは会議の長尺書き起こしも
> 扱うので判断が異なる。こちらの用途では `DictationTranscriber` のほうが適合する見込み。

**未決: Day-1 スパイク。** 同一の日本語 WAV に対して両者を走らせ、
句読点・固有名詞・レイテンシを比較してから確定する。
`TranscriptionProvider` の接合部があるので、これは 40 行の実験で済み、リファクタにならない。

既定の想定:

```swift
DictationTranscriber(
    locale: jaJP,
    contentHints: [],                       // 下記の勘所を参照
    transcriptionOptions: [.punctuation],
    reportingOptions: [.volatileResults],
    attributeOptions: []
)
```

### 勘所: `.shortForm` を既定にしない

短い発話を想定するヒントだが、**長い発話では区切りを誤り、
意味のない断片が混ざる**。実際に

```
〜ゴルフをする。aゴルフは9時8分スタートで、終了は13時位かな。a13時位から〜
```

のように、和文の句読点の直後に単独の ASCII 文字が現れた
（LLM ではなく認識側の混入であることを切り分けて確認した）。

発話の長さは押す前には分からないので、既定ではヒントを渡さない。
保険として `TranscriptBuffer.removeStrayFragments` が
和文の句読点直後の単独 ASCII 英字を落とす。

**この除去は英文を壊してはいけない。**
最初の実装は "I went to Tokyo. A penguin…" の `I` と `A` を消していた。
和文の句読点（。、！？）に続く場合だけに限定すること。
直後が英字なら単語の途中なので残し（`。Slack` の S）、
数字なら落とす（`。a13時` は認識の誤り）。

## 音声取り込み

### 勘所 1: モノラルの tap フォーマットを engine に要求する

**`AVAudioConverter` は非標準のマルチチャネルレイアウト (6ch USB オーディオ I/F 等) を
モノラルにダウンミックスさせると、エラーを返さずゼロ埋めのバッファを返す。**
無音として認識され、原因が全く分からないバグになる。

回避策は、変換ではなく **`installTap` の時点でモノラルを要求する**こと。
`AVAudioEngine` 側のダウンミックスは任意のレイアウトを正しく扱える。

```swift
let hw = inputNode.outputFormat(forBus: 0)     // 例: 48000 Hz, 2 ch, Float32

// サンプルレートは hw と一致させること。変えると installTap が throw する。
// 変えてよいのはチャネル数だけ。
let tapFormat = hw.channelCount == 1 ? hw : AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: hw.sampleRate,
    channels: 1,
    interleaved: false)!

inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, when in ... }
```

これで `AVAudioConverter` の仕事は
**48 kHz mono Float32 → 16 kHz mono Int16** のリサンプルと型変換だけになり、
ダウンミックスが発生しないのでゼロ埋めバグを踏まない。

> **規則: `AVAudioConverter` は 1ch → 1ch でのみ信用する。チャネル削減は `AVAudioEngine` の仕事。**

4096 フレーム @ 48 kHz = 約 85 ms。レイテンシとオーバーヘッドのバランスが良い。

### tap コールバック本体

tap スレッドで同期的に走る。**10 行以内に保つ。**

```swift
// nonisolated
{ [box, continuation] buffer, time in
    guard let out = box.convert(buffer) else { return }
    continuation.yield(AudioChunk(buffer: out, startTime: time.cmTime))
}
```

`box` は `AVAudioConverter` を持つ `final class: @unchecked Sendable`。
**tap スレッドからしか、かつ直列にしか触らない**という不変条件を宣言箇所にコメントで書く。

`AsyncStream.Continuation.yield` はロックを取り確保もしうるのでリアルタイム安全ではないが、
`installTap` はレンダースレッドではなく専用ディスパッチキューで動くため問題にならない。
本体をこの短さに保つ限り安全。

### デバイス経路の変化

`AVAudioEngineConfigurationChange` を購読する。
AirPods の接続・切断、Mac のスリープ復帰で入力フォーマットが変わるので、
engine を停止 → tap 再設置 → 再開する。
録音中に起きた場合は現在のセッションを `failed` にして、生原稿があればそれを挿入する。

TypeWhisper はここに `AudioDeviceService.swift` 3,696 行を費やしている
(Bluetooth/USB/内蔵ごとの事前ウォームアップ方針、クラッシュ復旧用の音声保存など)。
**そこまではやらない。** 設定変更通知への対応と engine 再起動だけ実装し、
残りは実際に困ったら足す。

## プロバイダ抽象

### 形: ストリーミングを基本形にし、バッチは上に合わせる

```swift
public protocol TranscriptionProvider: Sendable {
    static var descriptor: ProviderDescriptor { get }

    func readiness(for request: TranscriptionRequest) async -> Readiness
    func fulfill(_ requirement: SetupRequirement) async throws -> PreparationHandle?

    /// 最初の音声バッファでモデルが冷えていないように温める。ホットキー押下時に呼ぶ。
    func prewarm(for request: TranscriptionRequest) async throws

    func startSession(_ request: TranscriptionRequest) async throws -> any TranscriptionSession
}

public protocol TranscriptionSession: Actor {
    /// 取り込み側が用意すべきフォーマット。プロバイダが決める。
    nonisolated var inputFormat: AudioFormatDescription { get }
    nonisolated var events: AsyncThrowingStream<TranscriptionEvent, any Error> { get }

    func append(_ chunk: AudioChunk) async throws
    func finish() async throws    // これ以上音声は来ない。flush して確定させる
    func cancel() async           // ユーザーが中断。以降何も emit しない
}

public enum TranscriptionEvent: Sendable {
    /// 暫定結果。直前の .partial を**丸ごと置き換える**。追記してはいけない。
    case partial(String)
    /// 確定結果。追記していく。
    case finalized(TranscriptSegment)
    case ended(TranscriptionSummary)
}
```

**なぜストリーミングを基本形にするか。**
バッチをストリーミングに合わせるのは情報を失わない (チャンクを溜めて `finish()` で
`.finalized` を 1 つ出すだけ)。逆にストリーミングをバッチに合わせると、
ホールド中に文字が育っていく体験が消える上、結局クリップ全体をバッファすることになる。
**情報を失わない方向に合わせる。**

**なぜプロトコルを 2 本にしないか。**
2 本にすると呼び出し側に 2 つのコードパス、2 つの HUD 状態、2 つのキャンセル経路、
2 つのエラー分類ができる。UI の形を実際に変える能力は「暫定結果を出せるか」だけで、
それは `descriptor` の `Bool` 1 つ。他 (対応ロケール、用語ヒント) は**形ではなくデータ**である。

バッチプロバイダ用のアダプタ:

```swift
/// クラウド/バッチ系プロバイダはこれを内包する。PCM を溜めて finish() で送る。
public actor BufferingTranscriptionSession: TranscriptionSession {
    public init(inputFormat: AudioFormatDescription,
                maxDuration: Duration,
                upload: @Sendable @escaping (Data, AudioEncoding, TranscriptionRequest) async throws -> String)
}
```

### `AudioChunk` — `AVFoundation` 型を外に漏らさない

`AnalyzerInput` は `AVAudioPCMBuffer` を包んでおり `@unchecked Sendable` でしかない。
これを自分の API に伝播させない。

```swift
public struct AudioFormatDescription: Sendable, Hashable {
    public let sampleRate: Double          // 16_000
    public let channelCount: Int           // 1
    public let sampleFormat: SampleFormat  // .int16LE | .float32
}

public struct AudioChunk: Sendable {
    public let format: AudioFormatDescription
    public let hostTime: UInt64?
    public let samples: Data               // format に沿ったインターリーブ PCM
}
```

16 kHz mono Int16 の 100 ms = 3,200 バイト。この頻度ならコピーは無視できる。
Apple プロバイダ内で `AVAudioPCMBuffer` を再構築するのは 100 ms あたり 1 確保で済む。

### リクエスト

```swift
public struct TranscriptionRequest: Sendable {
    public var locale: Locale                  // Locale(identifier: "ja-JP")
    public var termHints: [TermHint]
    public var wantsPartialResults: Bool
    public var maxDuration: Duration           // 上限。バッチ系のメモリを守る
    public var punctuation: PunctuationMode    // .automatic | .off
}

public struct TermHint: Sendable, Hashable {
    public let text: String
    public let boost: Float?                   // nil = プロバイダ既定
}
```

## 社内用語辞書 (term hints)

`AnalysisContext.contextualStrings[.general]` に語を渡すと認識がそちらに寄る。
社名・製品名・略語・よく出る人名を入れておくと日本語の精度が目に見えて上がる。
**社内ツールとしての差別化ポイント。**

```swift
let context = AnalysisContext()
context.contextualStrings[.general] = hints.map(\.text)
try await analyzer.setContext(context)
```

プロバイダ間のマッピング (`TermHint` を抽象として持つ理由):

| プロバイダ | 対応 |
|---|---|
| Apple | `analysisContext.contextualStrings[.general]`。`boost` は無視 |
| OpenAI Whisper API | `prompt` パラメータ。`、` で連結し **約 224 トークンで打ち切り** (API の上限) |
| Deepgram | `keyterm[]` / `keywords[]` (boost をネイティブ対応) |
| Google STT v2 | `speechContexts[].phrases` + `boost` |

**上限を設ける。** 100 語 / 2,000 文字でキャップし、重複を除いてから渡す。
`contextualStrings` が長すぎると Apple の精度は**むしろ落ちる**。
TypeWhisper も同じ理由で上限を設けて warning を出している。

設定では素の文字列配列で持ち、人が編集できるようにする:

```jsonc
"termHints": ["kintone", "サイボウズ", "Garoon", "voinp"],
"termHintsFile": null    // 大きい辞書は 1 行 1 語の別ファイルへ
```

**未決: 配布方法。** 社内用語辞書をどうチームで共有するか
(config 直書き / 別ファイルを配る / 社内 Git から取得) は決めていない。
まずは `termHintsFile` で 1 行 1 語のテキストを読む形にしておき、
そのファイルを社内 Git に置けば当面回る。

## 準備状態 (readiness) — 資産ダウンロードと資格情報を 1 つの概念に

ローカルエンジンは初回にモデル資産のダウンロードが要る。
クラウドプロバイダは代わりに API キーが要る。
どちらも**「一度だけユーザーがやる必要があり、アプリが誘導または代行できること」**なので統一する。

```swift
public enum Readiness: Sendable, Equatable {
    case ready
    case needsSetup([SetupRequirement])
    case unsupported(reason: String)
}

public enum SetupRequirement: Sendable, Equatable, Identifiable {
    case modelAssets(locale: Locale, status: AssetStatus)
    case localeReservation(Locale)
    case credential(CredentialRef)
    case endpoint(configField: String)
    case modelSelection(configField: String)
    case systemPermission(SystemPermission)      // .microphone / .accessibility
    case networkPermission(required: EgressClass)
}

public struct PreparationHandle: Sendable {
    public let progress: AsyncStream<Double>     // 0.0...1.0
    public let cancel: @Sendable () -> Void
    public let completion: Task<Void, any Error>
}
```

設定画面は `[SetupRequirement]` を汎用的に描画する:
ラベル + アクションボタン + 任意のプログレスバー。
`.modelAssets` はプログレスバー、`.credential` はセキュアテキストフィールド、
`.networkPermission` はプライバシー画面へ飛ぶトグル。

### Apple プロバイダの実装

```swift
func readiness(for r: TranscriptionRequest) async -> Readiness {
    guard SpeechTranscriber.isAvailable else { return .unsupported(reason: "…") }

    // 設定の "ja-JP" は必ずこれで正規化する。Locale(identifier:) が
    // フレームワークの資産インデックスと一致する保証はない。
    guard let canonical = await DictationTranscriber.supportedLocale(equivalentTo: r.locale) else {
        return .unsupported(reason: "\(r.locale.identifier) は未対応です")
    }

    let t = makeTranscriber(locale: canonical, request: r)
    var reqs: [SetupRequirement] = []

    switch await AssetInventory.status(forModules: [t]) {
    case .installed:   break
    case .downloading: reqs.append(.modelAssets(locale: canonical, status: .downloading))
    case .supported:   reqs.append(.modelAssets(locale: canonical, status: .supported))
    case .unsupported: return .unsupported(reason: "…")
    }

    if await !AssetInventory.reservedLocales.contains(canonical) {
        reqs.append(.localeReservation(canonical))
    }
    return reqs.isEmpty ? .ready : .needsSetup(reqs)
}

func fulfill(_ req: SetupRequirement) async throws -> PreparationHandle? {
    switch req {
    case .modelAssets(let locale, _):
        let t = makeTranscriber(locale: locale, request: .default)
        guard let install = try await AssetInventory.assetInstallationRequest(supporting: [t]) else {
            return nil    // 既に入っている
        }
        let (stream, cont) = AsyncStream<Double>.makeStream()
        let obs = install.progress.observe(\.fractionCompleted) { p, _ in
            cont.yield(p.fractionCompleted)
        }
        let task = Task {
            defer { obs.invalidate(); cont.finish() }
            try await install.downloadAndInstall()
        }
        return PreparationHandle(progress: stream,
                                 cancel: { install.progress.cancel(); task.cancel() },
                                 completion: task)

    case .localeReservation(let locale):
        _ = try await AssetInventory.reserve(locale: locale)
        return nil

    default: return nil
    }
}
```

### 勘所 2: `reserve(locale:)` は必須

予約していないロケールの資産は **OS に削除されうる**。
そうなると数週間後に突然また初回ダウンロードが走り、原因が分からない不具合になる。

起動時に設定のロケールを `reserve` し、
ユーザーが設定でロケールを変えたときに古いほうを `release` する。
`maximumReservedLocales` は 5 なので、6 個目を追加しようとしたら UI で伝える。

`SpeechTranscriber.installedLocales` に `ja-JP` が含まれていても
`AssetInventory.status(forModules:)` が `.supported` を返すことがある (実測で確認)。
**`installedLocales` を当てにせず、必ず `status(forModules:)` で判定する。**

## ライブセッションの実装

TypeWhisper の `SpeechAnalyzerLiveSession` で動作が確認できている形。

```swift
actor AppleTranscriptionSession: TranscriptionSession {
    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var didFinish = false

    init(locale: Locale, request: TranscriptionRequest) async throws {
        transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            transcriptionOptions: request.punctuation == .automatic ? [.punctuation] : [],
            reportingOptions: request.wantsPartialResults ? [.volatileResults] : [],
            attributeOptions: [])

        analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated,
                                            modelRetention: .processLifetime))
        // ...
    }
}
```

結果の消費。**`isFinal` が確定/暫定の判別のすべて**である
(`SpeechModuleResult` の extension プロパティ。手で volatile range を追う必要はない):

```swift
for try await result in transcriber.results {
    let text = String(result.text.characters)
    if result.isFinal {
        yield .finalized(TranscriptSegment(text: text, ...))
    } else {
        yield .partial(text)      // 直前の暫定を置き換える
    }
}
```

終了:

```swift
continuation.finish()
try await analyzer.finalizeAndFinishThroughEndOfInput()
```

キャンセル:

```swift
await analyzer.cancelAndFinishNow()
continuation.finish()
```

`finalizeAndFinishThroughEndOfInput()` は 3 秒でタイムアウトさせ、
超えたら確定済みの分だけ採用する。ハングさせない。

### 勘所 3: 起動レイテンシを消す 2 つの設定

```swift
SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
```

`modelRetention` の既定 `.whileInUse` だとディクテーション間でモデルがアンロードされ、
**毎回ホットキーを押すたびに数百 ms 待たされる**。
`.processLifetime` は RAM と引き換えに即時起動を得る。メニューバー常駐アプリには正しい取引。

合わせて **アプリ起動時に** `analyzer.prepareToAnalyze(in: format)` を呼ぶ。
ホットキー押下時ではなく起動時。

## 言語の自動判定はできない（エンジンの能力であってアプリの実装ではない）

**Apple の `SpeechAnalyzer` に言語自動判定はない。**

- `DictationTranscriber(locale:)` は**単一ロケール固定**。`selectedLocales` は読み取り専用
- `Speech.framework` に `languageIdentification` 等の API は存在しない
  （swiftinterface 全文検索でゼロ）
- `SpeechModule` は `DictationTranscriber` / `SpeechTranscriber` / `SpeechDetector` の 3 つだけで、
  `SpeechDetector` は発話区間の検出であって言語判定ではない

したがって `transcription.locale` の決め打ちになる。
日本語設定のまま英語を話せば、日本語として当てはめられる。

### TypeWhisper に「自動」があるのはなぜか

調べた結果、**アプリの独自実装ではなくエンジン側の機能**だった。

```swift
// WhisperKitPlugin.swift:423
detectLanguage: language == nil,
```

Whisper はモデル自体に言語判定トークンを持つので、WhisperKit を選んだときだけ
「自動」が機能する。同じアプリの `SpeechAnalyzerPlugin` は

```swift
detectedLanguage: locale.language.languageCode?.identifier
```

と、**設定値をそのまま返しているだけ**で判定していない。
Speechmatics プラグインにも「言語判定はバッチ専用機能」というコメントがある。

| エンジン | 自動判定 |
|---|---|
| Whisper 系 (WhisperKit / OpenAI API) | できる（モデルの能力） |
| Apple `SpeechAnalyzer` | **できない** |
| Speechmatics | バッチのみ |

**自動判定は選んだエンジンの能力に依存する。** UI に「自動」を出すかどうかは
プロバイダごとの能力で決めるべきで、step 2 で複数エンジンを持つときは
`ProviderDescriptor` に `supportsLanguageDetection` を持たせ、
対応するエンジンを選んだときだけ選択肢に出す。

### いまの方針

step 1 は **ja-JP 固定**。複数言語を使い分けたくなったら、
ホットキーを言語ごとに割り当てるのが現実的
（話す前にどちらか決まっているので、自動判定より確実で速い）。

## ダウンロード待ち UI をどう確認するか

**本物の音声モデルは削除できない。**
`Speech.framework` にアンインストール API はなく（`AssetInventory` は
`reserve` / `release` / `status` のみ）、実体は SIP 保護下の
`/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition`
（実測 721 MB）にあり、**macOS 標準のディクテーションと Siri が共用**している。

つまり「未取得の状態」を手元で再現できないので、
取得中の UI が正しく動くかを確かめる手段が要る。
`TranscriptionProvider` の接合部に差し替え実装を挿すのがこれにあたる
（接合部を作った実利の 1 つ）。

```sh
make run-sim        # 0→100% の進捗を返す
make run-sim-slow   # 進捗を返さない（本物と同じ挙動）
```

### 勘所: 本物のダウンロードは進捗を返さない

実測すると `AssetInstallationRequest.progress` は
**`fractionCompleted` が 0.0 のまま完了する**（`completedUnitCount = 0/1`）。

```
… 5s progress=0.0 completed=0/1
完了
```

素直に `ProgressView(value:)` を出すと **0% で固まったように見えてから一気に終わる**。
進捗が一度でも 0 を超えたときだけ確定バーを出し、そうでなければ不定表示にする。
`make run-sim-slow` はこの経路を再現する。

### 勘所: 予約はプロセスごと

`AssetInventory` の予約は**プロセス単位**で、新しいプロセスは必ず
`reservedLocales = []` から始まる。
**未予約のロケールは、資産がディスク上にあっても `status` が `.supported`
（未インストール）と報告される。**

```
reserve(ja-JP) → true
status: installed     ← 予約した瞬間に変わる
```

予約せずに `status` を見ると**起動のたびに「モデル未取得」と誤判定**し、
セットアップが毎回ダウンロードを促すことになる（実際にそうなっていた）。
`readiness()` の中で `status` を見る前に予約すること。予約は冪等で、同時 5 ロケールまで。

## クラウド STT（実装済み・オプトイン）

`gpt-live-transcribe` を OpenAI Realtime 互換の WebSocket で使う。
**プロトコルは変更していない。** `TranscriptionProvider` / `TranscriptionSession` に
そのまま載っている。

### 実測で確定したこと（社内 Azure / プロキシ経由）

| 項目 | 結果 |
|---|---|
| `?intent=transcription` | **必須**。付けない URL は 101 が返らない |
| `rate` | **24000 固定**。16000 は拒否される: "PCM input rate must be 24000, or 16000 for MAI transcription." |
| ハンドシェイク | **1,089 ms**（`session.created` → `session.update` → `session.updated`） |
| 社内 PAC 経由の `wss` | 通る。squid は CONNECT を通し Upgrade も剥がさない |
| PAC のスキーム分岐 | この環境では `wss` と `https` で同じ答え。写像は保険として残す |
| 認証 | Azure は `api-key: <生キー>`、OpenAI は `Authorization: Bearer` |

### セッション設定

```json
{ "type": "session.update",
  "session": { "type": "transcription",
    "audio": { "input": {
      "format": { "type": "audio/pcm", "rate": 24000 },
      "transcription": {
        "model": "gpt-live-transcribe",
        "languages": ["ja", "en"],
        "keywords": ["kintone", "Garoon"],
        "prompt": "", "delay": "low" },
      "noise_reduction": { "type": "near_field" },
      "turn_detection": null } } } }
```

- **`noise_reduction` は `transcription` の中ではない。** `audio.input` 直下。
  位置を間違えると設定全体が拒否される
- **`keywords` に `<` `>` を入れない。** 入ると `session.update` 全体が拒否される。
  64 語まで、`prompt` は 1,000 文字まで
- `turn_detection` は `null`。voinp はホットキーで区切るので、
  サーバーにターンを切られると確定のタイミングが読めなくなる
- **`languages` で複数言語ヒントを渡せる。** macOS の `SpeechAnalyzer` には無い機能で、
  日英混在（「kintone の API で 401 が返る」）に効く
- `keywords` は voinp の `termHints` がそのまま対応する

### 勘所: `delta` は追記、`.partial` は置換

意味論が逆を向いている。

| | 意味 |
|---|---|
| Realtime の `delta` | **追記分** |
| voinp の `.partial` | 直前を**丸ごと置換** |

素通しすると HUD に最後の断片しか出ない。`RealtimeTranscriptAssembler` が
累積してから置換として出す。併せて:

- 同じ `item_id` の `completed` は 1 度しか確定させない（文が二重に入る）
- **空の `completed` で暫定を殺さない。** `TranscriptBuffer` は `.finalized` を受けると
  `volatileTail` を捨てるので、空で出すと `bestEffortText` が空になる
- `audioRange` は付けない（Realtime は音声区間を返さない）。そのぶん
  `TranscriptBuffer` の重複排除が効かないので、重複排除はアセンブラが担保する。
  **Apple 版と責任分担が逆**になる

### 勘所: 接続を待つとマイクが閉じている

`DictationCoordinator.startCapture` は `startSession()` が返るまでマイクを開かない。
ハンドシェイクは実測 1,089 ms なので、そこで待つと**その 1 秒は発話が物理的に存在しない**。

→ `startSession()` は接続を待たずに返す。接続中の音声は `PrerollBuffer`（上限 15 秒）へ
積み、`session.updated` を受けた瞬間に順番に吐き出す。
`append()` も待たない（`pumpTask` が直列なので、待つと `AudioCapture` が溢れて中抜けする）。

### 退避

`FallbackTranscriptionProvider` が吸収する。`DictationCoordinator` と
`SessionMachine` は**無変更**。

| 状況 | 動作 |
|---|---|
| 開始前に使えない | 最初からローカル。ユーザーには見えない |
| 確定 0 件で切れた | ローカルを起こし、**保持した音声をリプレイ**。HUD に退避を表示 |
| 確定が出た後に切れた | 差し替えない（音声区間が特定できず文が二重になる） |

**`events` をエラーで終わらせない。** `DictationCoordinator.resultTask` は `catch` で
`.failed` を dispatch し、`SessionMachine` が `abortEverything` に落ちて
それまでの認識結果を全部捨てる。どんな失敗も「溜まった分を確定して正常終了」に変換する。

退避時は 24kHz の音声を 16kHz の Apple エンジンへ流すので、
`AppleSpeechProvider` が `chunk.format` を見て変換する。
変換しないと**無言で 1.5 倍速**になり、エラーも出ないまま認識だけが壊れる。

### ローカルや社内 GPU に向けることもできる

接続先を `ws://127.0.0.1:8899/v1/realtime` のような自前のサーバに向ければ、
到達範囲は `loopback` のままで `audioLeavesMachine` は false になる。
社内 GPU に Realtime 互換サーバを立てる構成なら `privateNetwork` になる。

### readiness で通信しない

`readiness` は `startCapture` の先頭から毎回呼ばれる＝**ホットキーを押すたびに走る**。
往復を入れると、会社の外にいるときに押すたびタイムアウトを待つことになる。
監査ログに「ユーザーが何もしていないのに出た通信」が溜まるのも避けたい。
見るのはローカルで分かることだけ（URL の形・モデル名・鍵の有無）。
疎通確認は設定画面の接続テストで行う。
