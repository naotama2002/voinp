import Foundation

/// セッションの純粋な reducer。macOS API を一切触らないため、
/// GUI もマイクも権限もなしに全遷移をテストできる。
///
/// Clock は注入しない。`handle` が時刻を引数で受け取ることで、
/// `TestClock` のような仕掛けなしに完全に決定的になる。
public struct SessionMachine: Sendable {

    public struct Limits: Sendable {
        public var minRecording: Duration = .milliseconds(250)
        public var modifierWaitSoft: Duration = .milliseconds(500)
        public var modifierWaitHard: Duration = .seconds(3)
        public var failureDismiss: Duration = .seconds(4)
        public init() {}
    }

    public private(set) var phase: SessionPhase = .idle

    private let limits: Limits
    private var target: InsertionTarget?
    private var recordingStarted: ContinuousClock.Instant?
    private var buffer = TranscriptBuffer()
    /// いま挿入しようとしているテキスト。
    /// 失敗時のフォールバックで**これ**を退避する。
    /// buffer.finalText だと、校正で変わった内容や
    /// 暫定分しか無かった場合を取りこぼす（空文字を貼ってしまう）。
    private var pendingText: String?

    public init(limits: Limits = Limits()) { self.limits = limits }

    public mutating func handle(
        _ event: SessionEvent,
        at now: ContinuousClock.Instant
    ) -> [SessionAction] {
        switch (phase, event) {

        // ── 開始 ──────────────────────────────────────────────
        case (_, .startRequested(let t)) where phase.acceptsNewSession:
            guard !t.isSecureInput else {
                phase = .failed(.secureInputActive)
                return [.play(.error), .showHUD, .scheduleDismiss(after: limits.failureDismiss)]
            }
            target = t
            buffer.reset()
            phase = .arming
            return [.startCapture(t), .showHUD, .play(.start)]

        // セッション中の再要求は無視する。セッションは絶対に重ねない。
        case (_, .startRequested):
            return [.play(.error)]

        case (.arming, .audioStarted):
            recordingStarted = now
            phase = .listening(buffer.snapshot())
            return []

        // ── モデル初回ダウンロード ────────────────────────────
        // arming から入るのが初回。ここで実際に取得を始めないと、
        // 進捗 0% の表示のまま永久に何も起きない。
        case (.arming, .modelProgress(let p)):
            phase = .installingModel(progress: p)
            return [.installModel]

        case (.installingModel, .modelProgress(let p)):
            phase = .installingModel(progress: p)
            return []

        case (.installingModel, .modelReady):
            phase = .arming
            return target.map { [.startCapture($0)] } ?? []

        // ── 認識中 ────────────────────────────────────────────
        case (.listening, .transcript(let e)):
            buffer.apply(e)
            phase = .listening(buffer.snapshot())
            return []

        case (.listening, .stopRequested), (.arming, .stopRequested):
            // 素早いタップ。短すぎる録音は空挿入を防ぐためキャンセル扱い。
            if let started = recordingStarted, now - started < limits.minRecording {
                return abort(reason: .tooShort)
            }
            phase = .finalizing
            return [.stopCaptureAndFinalize, .play(.stop)]

        case (.finalizing, .transcript(let e)):
            buffer.apply(e)
            return []

        case (.finalizing, .transcriptionFinished(let text)):
            let result = text.isEmpty ? buffer.finalText : text
            // 空の発話は校正も挿入もせず終わる
            guard !result.isEmpty else {
                phase = .idle
                return [.hideHUD, .play(.cancel)]
            }
            phase = .refining
            return [.refine(result)]

        // ── 校正 ──────────────────────────────────────────────
        // 校正は失敗しても生原稿が入ってくる。ここで分岐は要らない。
        case (.refining, .refinementFinished(let text)):
            phase = .awaitingModifierRelease(text: text)
            return [.waitForModifierRelease(text)]

        // ── 修飾キー待ち ──────────────────────────────────────
        case (.awaitingModifierRelease(let text), .modifiersReleased):
            guard let t = target else { return abort(reason: .modifiersStuck) }
            pendingText = text
            phase = .inserting
            return [.insert(text, into: t)]

        // 上限時間を超えたら諦める。誤った修飾キー付きでキーを送るより
        // ペーストボードに残すほうがましである。
        case (.awaitingModifierRelease(let text), .modifierWaitTimedOut):
            phase = .failed(.modifiersStuck)
            return [.copyToPasteboardAsFallback(text), .play(.error),
                    .scheduleDismiss(after: limits.failureDismiss)]

        case (.inserting, .insertionFinished):
            pendingText = nil
            phase = .idle
            return [.hideHUD]

        // ── キャンセル・失敗 ──────────────────────────────────
        case (_, .cancelRequested):
            return abort(reason: nil)

        // 挿入直前・挿入中の失敗はテキストを必ずペーストボードに残す。
        case (.awaitingModifierRelease(let text), .failed(let e)):
            phase = .failed(e)
            return [.copyToPasteboardAsFallback(text), .play(.error),
                    .scheduleDismiss(after: limits.failureDismiss)]

        case (.inserting, .failed(let e)):
            phase = .failed(e)
            let text = pendingText ?? buffer.bestEffortText
            return [.copyToPasteboardAsFallback(text), .play(.error),
                    .scheduleDismiss(after: limits.failureDismiss)]

        case (_, .failed(let e)):
            phase = .failed(e)
            return [.abortEverything, .play(.error),
                    .scheduleDismiss(after: limits.failureDismiss)]

        case (.failed, .dismissRequested):
            phase = .idle
            return [.hideHUD]

        default:
            return []
        }
    }

    private mutating func abort(reason: SessionError?) -> [SessionAction] {
        let wasActive = phase != .idle
        if let reason {
            phase = .failed(reason)
            return [.abortEverything, .play(.error),
                    .scheduleDismiss(after: limits.failureDismiss)]
        }
        phase = .idle
        return wasActive ? [.abortEverything, .hideHUD, .play(.cancel)] : []
    }
}
