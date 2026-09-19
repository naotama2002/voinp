import Foundation

public enum SessionEvent: Equatable, Sendable {
    case startRequested(target: InsertionTarget)
    /// 録音を止める。`thenEdit` なら挿入せず編集ウィンドウを開く。
    /// **既定は false**（＝今までどおり即挿入）。遅くなる経路を既定にしない。
    case stopRequested(thenEdit: Bool = false)
    case cancelRequested
    case modelProgress(Double)
    case modelReady
    case audioStarted
    case transcript(TranscriptionEvent)
    case transcriptionFinished(text: String)
    case refinementFinished(text: String)
    /// 編集ウィンドウで確定した。この文字列を挿入する。
    case editApplied(text: String)
    /// 編集ウィンドウを閉じて破棄した。
    case editCancelled
    /// 挿入先アプリを前面に戻し終えた。
    case focusRestored
    case modifiersReleased
    case modifierWaitTimedOut
    case insertionFinished(InsertionOutcome)
    case failed(SessionError)
    case dismissRequested
}

public enum SessionAction: Equatable, Sendable {
    case installModel
    case startCapture(InsertionTarget)
    case stopCaptureAndFinalize
    case abortEverything
    case refine(String)
    /// 編集ウィンドウを開く。**この間 voinp が最前面になる。**
    case presentEditor(String)
    case dismissEditor
    /// 編集で奪ったフォーカスを挿入先へ返す。挿入はそのあと。
    case restoreFocus(InsertionTarget)
    case waitForModifierRelease(String)
    case insert(String, into: InsertionTarget)
    case copyToPasteboardAsFallback(String)
    case showHUD
    case hideHUD
    case play(Feedback)
    case scheduleDismiss(after: Duration)
}
