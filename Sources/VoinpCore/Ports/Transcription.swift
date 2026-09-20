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
    /// 明示の読み。**ASCII の語には要る。**
    /// `kintone` は自動では「きんとね」と読まれ（ローマ字読み）、
    /// 実際の発音「きんとーん」と離れてしまう。
    public let reading: String?

    public init(_ text: String, reading: String? = nil) {
        self.text = text
        self.reading = reading
    }

    /// 設定 1 行を読む。`kintone きんとーん` / `kintone,きんとーん` / `kintone` のいずれも受ける。
    /// **読みを書かなくても動く**ことを崩さない（既存の辞書がそのまま使える）。
    public static func parse(_ line: String) -> TermHint? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let parts = t.split(whereSeparator: { $0 == "," || $0 == "\t" || $0 == " " || $0 == "　" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let head = parts.first else { return nil }
        return TermHint(head, reading: parts.count > 1 ? parts[1] : nil)
    }

    /// 比較に使う形の読み。
    public var comparableReading: String {
        JapaneseReading.normalize(reading ?? JapaneseReading.reading(of: text))
    }
}

public struct TranscriptionRequest: Sendable {
    public var locale: Locale
    public var termHints: [TermHint]
    public var wantsPartialResults: Bool
    public var punctuation: Bool
    /// 短い発話を想定するか。
    /// エンジンにヒントを渡すが、長い発話で誤ると断片が混ざるので既定は false。
    public var expectsShortUtterance: Bool

    public init(locale: Locale, termHints: [TermHint] = [],
                wantsPartialResults: Bool = true, punctuation: Bool = true,
                expectsShortUtterance: Bool = false) {
        self.locale = locale; self.termHints = termHints
        self.wantsPartialResults = wantsPartialResults; self.punctuation = punctuation
        self.expectsShortUtterance = expectsShortUtterance
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
