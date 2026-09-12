import AVFoundation
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

    private func makeTranscriber(locale: Locale, request: TranscriptionRequest) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            transcriptionOptions: request.punctuation ? [.punctuation] : [],
            reportingOptions: request.wantsPartialResults ? [.volatileResults] : [],
            attributeOptions: [])
    }

    public func readiness(for request: TranscriptionRequest) async -> Readiness {
        guard let canonical = await DictationTranscriber.supportedLocale(equivalentTo: request.locale)
        else { return .unsupported("\(request.locale.identifier) は未対応です") }

        let t = makeTranscriber(locale: canonical, request: request)
        // installedLocales は当てにならない。必ず status(forModules:) で判定する。
        switch await AssetInventory.status(forModules: [t]) {
        case .installed:   return .ready
        case .supported, .downloading: return .needsModelDownload(canonical)
        case .unsupported: return .unsupported("モデル資産が提供されていません")
        @unknown default:  return .unsupported("不明な状態")
        }
    }

    public func downloadModel(for locale: Locale,
                              progress: @Sendable @escaping (Double) -> Void) async throws {
        let canonical = await DictationTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let t = makeTranscriber(locale: canonical, request: .init(locale: canonical))

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            let p = request.progress
            let poll = Task.detached {
                while !Task.isCancelled && !p.isFinished {
                    progress(p.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
        }
        progress(1.0)

        // **予約しないと OS に資産を削除されうる。**
        // 数週間後に突然また初回ダウンロードが走る、という掴みにくい不具合になる。
        _ = try? await AssetInventory.reserve(locale: canonical)
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
                    cont.yield(result.isFinal ? .finalized(TranscriptSegment(text: text))
                                              : .partial(text))
                }
                cont.finish()
            } catch {
                cont.finish(throwing: error)
            }
        }
    }

    func append(_ chunk: AudioChunk) async throws {
        guard !didFinish, !chunk.samples.isEmpty else { return }
        guard let buffer = Self.buffer(from: chunk, format: audioFormat) else { return }
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

    private static func buffer(from chunk: AudioChunk, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytesPerFrame = chunk.format.isInt16 ? MemoryLayout<Int16>.size : MemoryLayout<Float>.size
        let frames = chunk.samples.count / bytesPerFrame
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)

        chunk.samples.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            if let dst = buf.int16ChannelData {
                dst[0].update(from: base.assumingMemoryBound(to: Int16.self), count: frames)
            } else if let dst = buf.floatChannelData {
                dst[0].update(from: base.assumingMemoryBound(to: Float.self), count: frames)
            }
        }
        return buf
    }
}
