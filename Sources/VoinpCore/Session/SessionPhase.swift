import Foundation

public enum SessionPhase: Equatable, Sendable {
    case idle
    case installingModel(progress: Double)
    case arming
    case listening(TranscriptSnapshot)
    case finalizing
    case refining
    /// 編集ウィンドウが開いている。**この間 voinp が最前面**で、HUD は隠す。
    case editing(text: String)
    /// 編集で奪ったフォーカスを挿入先へ返している最中。
    case restoringFocus(text: String)
    /// PTT の修飾キーがまだ押されている。離れるまで挿入してはいけない。
    case awaitingModifierRelease(text: String)
    case inserting
    case failed(SessionError)

    public var isListening: Bool { if case .listening = self { true } else { false } }

    /// voinp 自身がキーフォーカスを持っている段階。HUD を出すと二重表示になる。
    public var isEditing: Bool {
        switch self {
        case .editing, .restoringFocus: true
        default: false
        }
    }

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

extension SessionPhase {
    /// ログに出してよい表現。**本文を絶対に含まない。**
    ///
    /// `String(describing:)` は associated value をそのまま展開するため、
    /// `.listening` や `.awaitingModifierRelease(text:)` を素で補間すると
    /// 発話内容が unified log に載り、任意の管理ツールから読めてしまう。
    /// `os.log` の既定は `.public` なので、これは現実的な漏洩経路である。
    public var logDescription: String {
        switch self {
        case .idle: "idle"
        case .installingModel(let p): "installingModel(\(Int(p * 100))%)"
        case .arming: "arming"
        case .listening(let s): "listening(\(s.fullText.count)文字)"
        case .finalizing: "finalizing"
        case .refining: "refining"
        case .editing(let t): "editing(\(t.count)文字)"
        case .restoringFocus(let t): "restoringFocus(\(t.count)文字)"
        case .awaitingModifierRelease(let t): "awaitingModifierRelease(\(t.count)文字)"
        case .inserting: "inserting"
        case .failed(let e): "failed(\(e.logDescription))"
        }
    }
}

extension SessionError {
    /// ログ用。理由だけを出し、本文は含まない。
    public var logDescription: String {
        switch self {
        case .secureInputActive: "secureInputActive"
        case .permissionMissing(let p): "permissionMissing(\(p))"
        case .audioUnavailable(let e): "audioUnavailable(\(e))"
        case .transcriptionFailed(let e): "transcriptionFailed(\(e))"
        case .tooShort: "tooShort"
        case .insertionFailed(let e): "insertionFailed(\(e))"
        case .modifiersStuck: "modifiersStuck"
        case .misconfigured: "misconfigured"
        }
    }
}
