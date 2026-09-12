import Foundation

/// 認識エンジンが出す 1 件の結果。
public enum TranscriptionEvent: Equatable, Sendable {
    /// 暫定結果。直前の `.partial` を**丸ごと置き換える**。追記してはいけない。
    case partial(String)
    /// 確定結果。確定分に追記する。
    case finalized(TranscriptSegment)
    /// このセッションの認識が終わった。
    case ended(TranscriptionSummary)
}

public struct TranscriptSegment: Equatable, Sendable {
    public let text: String
    /// 音声上の範囲。エンジンが報告しない場合は nil。
    public let audioRange: ClosedRange<Duration>?
    public let confidence: Double?

    public init(text: String, audioRange: ClosedRange<Duration>? = nil, confidence: Double? = nil) {
        self.text = text
        self.audioRange = audioRange
        self.confidence = confidence
    }
}

public struct TranscriptionSummary: Equatable, Sendable {
    public let fullText: String
    public let locale: Locale
    public let audioDuration: Duration
    public let providerID: String

    public init(fullText: String, locale: Locale, audioDuration: Duration, providerID: String) {
        self.fullText = fullText
        self.locale = locale
        self.audioDuration = audioDuration
        self.providerID = providerID
    }
}

/// UI に流す劣化ビュー。確定分と暫定分を分けて持つのは、
/// HUD が暫定分だけ `.secondary` で描くため。
public struct TranscriptSnapshot: Equatable, Sendable {
    public let committed: String
    public let volatileTail: String

    public static let empty = TranscriptSnapshot(committed: "", volatileTail: "")

    public init(committed: String, volatileTail: String) {
        self.committed = committed
        self.volatileTail = volatileTail
    }

    /// 挿入候補になる全文。
    public var fullText: String { committed + volatileTail }
}
