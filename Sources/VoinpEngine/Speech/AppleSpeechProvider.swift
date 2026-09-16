import AVFoundation
import CoreMedia
import Foundation
import Speech
import VoinpCore

/// macOS 26 の `SpeechAnalyzer` + `DictationTranscriber` による完全オンデバイス認識。
///
/// `DictationTranscriber` を使うのは `.punctuation` を持つため。
/// 日本語の句読点をエンジン側が補うので、校正をオフにしても実用になる
/// （`SpeechTranscriber` にはこのオプションが無い）。
public struct AppleSpeechProvider: TranscriptionProvider {
    public let identifier = "apple.speechanalyzer"

    public init() {}

    /// 設定 UI に出す言語の候補。
    /// `supportedLocales` は 50 以上あって選びにくいので、よく使うものに絞る。
    /// 他の言語は config.json に直接書けば使える。
    public static let commonLocales: [LocaleChoice] = [
        .init(identifier: "ja-JP", displayName: "日本語"),
        .init(identifier: "en-US", displayName: "English (US)"),
        .init(identifier: "en-GB", displayName: "English (UK)"),
        .init(identifier: "zh-CN", displayName: "中文（簡体）"),
        .init(identifier: "ko-KR", displayName: "한국어"),  // voinp:allow-script
        .init(identifier: "de-DE", displayName: "Deutsch"),
        .init(identifier: "fr-FR", displayName: "Français"),
        .init(identifier: "es-ES", displayName: "Español"),
    ]

    /// 自分が予約したロケールを覚えておき、別のロケールに移るとき解放する。
    ///
    /// `AssetInventory` の同時予約は **5 が上限**で、超えると
    /// `assetInstallationRequest` が "Too many allocated locales" で失敗する。
    /// 予約しっぱなしにすると、ロケールを変えるたびに枠を食い潰す。
    private static let reservations = Reservations()

    final class Reservations: @unchecked Sendable {
        private let lock = NSLock()
        private var held: Set<String> = []

        /// 目的のロケールだけを予約状態にする。他は解放する。
        func ensureOnly(_ locale: Locale) async {
            let id = locale.identifier
            let toRelease: [String] = lock.withLock {
                let others = held.subtracting([id])
                held = [id]
                return Array(others)
            }
            for other in toRelease {
                _ = await AssetInventory.release(reservedLocale: Locale(identifier: other))
            }
            _ = try? await AssetInventory.reserve(locale: locale)
        }

        /// 上限に当たったときの最後の手段。自分の予約を全部手放す。
        func releaseAll() async {
            let all: [String] = lock.withLock { let h = Array(held); held = []; return h }
            for id in all {
                _ = await AssetInventory.release(reservedLocale: Locale(identifier: id))
            }
        }
    }

    private func makeTranscriber(locale: Locale, request: TranscriptionRequest) -> DictationTranscriber {
        // **`.shortForm` を既定にしない。**
        // 短い発話を想定するヒントなので、長い発話では区切りを誤り、
        // 意味のない断片（単独の "a" など）が混ざることがある。
        // 長さが事前に分からない以上、ヒントなしのほうが安全。
        DictationTranscriber(
            locale: locale,
            contentHints: request.expectsShortUtterance ? [.shortForm] : [],
            transcriptionOptions: request.punctuation ? [.punctuation] : [],
            reportingOptions: request.wantsPartialResults ? [.volatileResults] : [],
            attributeOptions: [])
    }

    /// 取得済みかどうかの判定。
    ///
    /// **`status(forModules:)` を使い、その前にロケールを予約する。**
    /// 予約しないと、資産がディスク上にあっても `.supported`（未インストール）と
    /// 報告されるため、起動のたびに「モデル未取得」と誤判定してしまう。
    ///
    /// `assetInstallationRequest == nil` を判定に使う手も試したが、
    /// **取得済みでも要求オブジェクトを返すことがあり**、判定には使えなかった。
    ///
    /// 予約は上限 5。`Reservations` が目的のロケール以外を解放して枠を守る。
    public func readiness(for request: TranscriptionRequest) async -> Readiness {
        guard let canonical = await DictationTranscriber.supportedLocale(equivalentTo: request.locale)
        else { return .unsupported("\(request.locale.identifier) は未対応です") }

        await Self.reservations.ensureOnly(canonical)

        let t = makeTranscriber(locale: canonical, request: request)
        switch await AssetInventory.status(forModules: [t]) {
        case .installed:   return .ready
        case .supported, .downloading: return .needsModelDownload(canonical)
        case .unsupported: return .unsupported("モデル資産が提供されていません")
        @unknown default:  return .unsupported("不明な状態")
        }
    }

    public func downloadModel(for locale: Locale,
                              progress: @Sendable @escaping (Double) -> Void) async throws {
        Log.speech.info("モデル取得を開始: \(locale.identifier, privacy: .public)")
        let canonical = await DictationTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let t = makeTranscriber(locale: canonical, request: .init(locale: canonical))

        // **インストール要求の前に予約を手放す。**
        //
        // 予約枠を握ったまま要求すると "Too many allocated locales, 5 maximum" で失敗する。
        // 実測: 予約なしなら要求は通り、予約を持っていると通らない。
        // 予約は「取得済み資産を OS に削除させない」ためのものなので、
        // 取得が終わってからで間に合う。
        await Self.reservations.releaseAll()

        Log.speech.info("インストール要求を問い合わせ中…")
        let installRequest = try await AssetInventory.assetInstallationRequest(supporting: [t])

        if let request = installRequest {
            Log.speech.info("インストール要求あり。ダウンロード開始")
            let p = request.progress
            let poll = Task.detached {
                while !Task.isCancelled && !p.isFinished {
                    progress(p.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
            Log.speech.info("ダウンロード完了")
        } else {
            Log.speech.info("インストール要求なし（取得済み）")
        }
        progress(1.0)

        // **予約しないと OS に資産を削除されうる。**
        // 数週間後に突然また初回ダウンロードが走る、という掴みにくい不具合になる。
        await Self.reservations.ensureOnly(canonical)
    }

    public func preferredFormat(for request: TranscriptionRequest) async -> AudioFormatDescription {
        let canonical = await DictationTranscriber.supportedLocale(equivalentTo: request.locale)
                        ?? request.locale
        let t = makeTranscriber(locale: canonical, request: request)
        // ハードコードせずフレームワークに訊く（実測では 16kHz / 1ch / Int16）。
        guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            return AudioFormatDescription(sampleRate: 16000, channelCount: 1, isInt16: true)
        }
        return AudioFormatDescription(
            sampleRate: f.sampleRate,
            channelCount: Int(f.channelCount),
            isInt16: f.commonFormat == .pcmFormatInt16)
    }

    public func startSession(_ request: TranscriptionRequest) async throws -> any TranscriptionSession {
        let canonical = await DictationTranscriber.supportedLocale(equivalentTo: request.locale)
                        ?? request.locale
        let t = makeTranscriber(locale: canonical, request: request)
        return try await AppleSpeechSession(transcriber: t, request: request, locale: canonical)
    }
}

// MARK: - セッション

actor AppleSpeechSession: TranscriptionSession {
    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let audioFormat: AVAudioFormat
    /// 退避時のリサンプル用。**変換器は使い回す**（作り直すと継ぎ目にノイズが乗る）。
    private let resampler: AudioResampler
    private var didFinish = false
    private var resultTask: Task<Void, Never>?

    nonisolated let events: AsyncThrowingStream<TranscriptionEvent, any Error>
    private nonisolated let eventContinuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation

    init(transcriber: DictationTranscriber, request: TranscriptionRequest, locale: Locale) async throws {
        self.transcriber = transcriber
        // modelRetention: .processLifetime にしないと、ディクテーション間でモデルが
        // アンロードされ、毎回ホットキーを押すたびに数百 ms 待たされる。
        self.analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated,
                                            modelRetention: .processLifetime))

        let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                             channels: 1, interleaved: true)!
        self.audioFormat = fmt
        self.resampler = AudioResampler(target: fmt)

        let inputParts = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.inputContinuation = inputParts.continuation

        let eventParts = AsyncThrowingStream<TranscriptionEvent, any Error>.makeStream()
        self.events = eventParts.stream
        self.eventContinuation = eventParts.continuation

        // 社内用語辞書。長すぎるとむしろ精度が落ちるので上限を設ける。
        if !request.termHints.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = Array(request.termHints.map(\.text).prefix(100))
            try await analyzer.setContext(ctx)
        }
        try await analyzer.start(inputSequence: inputParts.stream)

        let cont = eventContinuation
        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    // isFinal が確定/暫定の判別のすべて。手で volatile range を追う必要はない。
                    if result.isFinal {
                        // **音声区間を必ず渡す。** 渡さないと TranscriptBuffer の
                        // 重複排除が働かず、エンジンが同じ区間を再確定してきたときに
                        // 文が二重になる。
                        cont.yield(.finalized(TranscriptSegment(
                            text: text, audioRange: Self.durationRange(result.range))))
                    } else {
                        cont.yield(.partial(text))
                    }
                }
                cont.finish()
            } catch {
                cont.finish(throwing: error)
            }
        }
    }

    func append(_ chunk: AudioChunk) async throws {
        guard !didFinish, !chunk.samples.isEmpty else { return }
        // **落としたら黙らない。** 無言で捨てると「音量は出ているのに 0 文字」に
        // なり、原因を掴むのに実機のログが要る（実際にそうなった）。
        guard let buffer = resampler.buffer(for: chunk) else {
            Log.audio.error("音声を変換できず破棄: \(chunk.format.sampleRate, privacy: .public)Hz → \(self.audioFormat.sampleRate, privacy: .public)Hz")
            return
        }
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }


    func finish() async throws {
        guard !didFinish else { return }
        didFinish = true
        inputContinuation.finish()
        // ハングさせない。3 秒で諦めて確定済みの分を採用する。
        let finalize = Task { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        _ = try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await finalize.value }
            group.addTask { try await Task.sleep(for: .seconds(3)); finalize.cancel() }
            try await group.next()
            group.cancelAll()
        }
        // **結果を全部流し切ってから閉じる。**
        // 先に閉じると最後の確定結果が捨てられ、確定テキストが空になる。
        await resultTask?.value
        eventContinuation.finish()
    }

    func cancel() async {
        guard !didFinish else { return }
        didFinish = true
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        resultTask?.cancel()
        eventContinuation.finish()
    }

    /// `CMTimeRange` を `ClosedRange<Duration>` に落とす。
    /// 不正な値（未確定など）は nil にして、時刻なしとして扱わせる。
    private static func durationRange(_ r: CMTimeRange) -> ClosedRange<Duration>? {
        let start = r.start.seconds
        let end = r.end.seconds
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
        return Duration.seconds(start)...Duration.seconds(end)
    }

}

/// 設定 UI 用の言語候補。
public struct LocaleChoice: Hashable, Sendable {
    public let identifier: String
    public let displayName: String
    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }
}
