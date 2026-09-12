import Foundation

public struct AudioFormatDescription: Hashable, Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let isInt16: Bool
    public init(sampleRate: Double, channelCount: Int, isInt16: Bool) {
        self.sampleRate = sampleRate; self.channelCount = channelCount; self.isInt16 = isInt16
    }
}

/// 認識エンジンに渡す音声の断片。`AVAudioPCMBuffer` を API 境界に漏らさないため、
/// バイト列として持つ（100ms / 16kHz mono Int16 = 3,200 バイトなのでコピーは無視できる）。
public struct AudioChunk: Sendable {
    public let format: AudioFormatDescription
    public let samples: Data
    public init(format: AudioFormatDescription, samples: Data) {
        self.format = format; self.samples = samples
    }
}

public struct TermHint: Hashable, Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

public struct TranscriptionRequest: Sendable {
    public var locale: Locale
    public var termHints: [TermHint]
    public var wantsPartialResults: Bool
    public var punctuation: Bool

    public init(locale: Locale, termHints: [TermHint] = [],
                wantsPartialResults: Bool = true, punctuation: Bool = true) {
        self.locale = locale; self.termHints = termHints
        self.wantsPartialResults = wantsPartialResults; self.punctuation = punctuation
    }
}

public enum Readiness: Equatable, Sendable {
    case ready
    case needsModelDownload(Locale)
    case unsupported(String)
}

/// 差し替え可能な音声認識。step2 のクラウド STT もこの形に載る
/// （チャンクを溜めて finish() で送り、`.finalized` を 1 つ出す）。
public protocol TranscriptionProvider: Sendable {
    var identifier: String { get }
    func readiness(for request: TranscriptionRequest) async -> Readiness
    func downloadModel(for locale: Locale,
                       progress: @Sendable @escaping (Double) -> Void) async throws
    func preferredFormat(for request: TranscriptionRequest) async -> AudioFormatDescription
    func startSession(_ request: TranscriptionRequest) async throws -> any TranscriptionSession
}

public protocol TranscriptionSession: Actor {
    nonisolated var events: AsyncThrowingStream<TranscriptionEvent, any Error> { get }
    func append(_ chunk: AudioChunk) async throws
    func finish() async throws
    func cancel() async
}
