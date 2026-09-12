import Foundation

public enum SessionEvent: Equatable, Sendable {
    case startRequested(target: InsertionTarget)
    case stopRequested
    case cancelRequested
    case modelProgress(Double)
    case modelReady
    case audioStarted
    case transcript(TranscriptionEvent)
    case transcriptionFinished(text: String)
    case refinementFinished(text: String)
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
    case waitForModifierRelease(String)
    case insert(String, into: InsertionTarget)
    case copyToPasteboardAsFallback(String)
    case showHUD
    case hideHUD
    case play(Feedback)
    case scheduleDismiss(after: Duration)
}
