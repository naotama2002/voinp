import Foundation

public enum SessionPhase: Equatable, Sendable {
    case idle
    case installingModel(progress: Double)
    case arming
    case listening(TranscriptSnapshot)
    case finalizing
    case refining
    /// PTT の修飾キーがまだ押されている。離れるまで挿入してはいけない。
    case awaitingModifierRelease(text: String)
    case inserting
    case failed(SessionError)

    public var isListening: Bool { if case .listening = self { true } else { false } }

    /// 新しいセッションを受け付けられるか。セッションは絶対に重ねない。
    public var acceptsNewSession: Bool {
        switch self {
        case .idle, .failed: true
        default: false
        }
    }
}

public struct InsertionTarget: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t
    public let isSecureInput: Bool

    public init(bundleIdentifier: String?, processIdentifier: pid_t, isSecureInput: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.isSecureInput = isSecureInput
    }
}

public enum InsertionOutcome: Equatable, Sendable {
    case inserted(strategy: String)
    case copiedToPasteboard
}

public enum Feedback: Equatable, Sendable {
    case start, stop, cancel, error
}
