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

## step 2: クラウド STT を載せる

プロトコルは変更不要。クラウドプロバイダは:

1. `inputFormat` に自分の望む形式を返す (取り込み側がそれに合わせる)
2. `append` でチャンクを溜める (`BufferingTranscriptionSession`)
3. `finish()` で WAV/FLAC/Opus にまとめて `EgressGate` 経由で POST
4. `.finalized` を 1 つと `.ended` を emit

`descriptor.supportsPartialResults = false` なので HUD は波形だけ出す。
`descriptor.egress` が `.fixedHosts(["api.openai.com"])` などになり、
`PrivacyPosture` が `.cloud` に変わって**メニューバーのアイコンが変わる** ([06](06-privacy.md))。

step 2 で初めて**音声が Mac の外に出る**。そのタイミングで、
`VoinpNet` を別プロセス (XPC) に切り出し、音声を扱うプロセスからネットワーク権限を
剥奪することを検討する。いまはやらない ([06](06-privacy.md) の D.3)。
