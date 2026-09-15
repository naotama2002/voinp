import Foundation

/// 実行時の失敗。`SessionError` より下のレイヤが投げる。
public enum VoinpError: Error, Equatable, Sendable {
    // 権限
    case microphoneNotGranted
    case accessibilityNotGranted

    // 音声認識
    case localeUnsupported(String)
    case modelAssetsMissing(String)
    case transcriberUnavailable

    // 挿入
    case noFocusedElement
    case axSetFailed
    case axSilentNoop
    case secureInputActive
    case pasteVerificationUnavailable
    /// 認識・校正を待つ間に、フォーカスが別のアプリへ移った
    case focusChangedDuringRecognition(expected: String?, actual: String?)

    // 送信ゲート
    case egressDenied(EgressDenialReason)

    // 設定
    case configUnreadable(String)
    case configVersionTooNew(found: Int, supported: Int)
}

/// `EgressGate` が送信前に拒否した理由。監査ログにそのまま載る。
public enum EgressDenialReason: Equatable, Sendable {
    case networkDisabled
    case hostNotAllowed(String)
    case classExceedsPolicy(requested: EgressClass, max: EgressClass)
    case proxyExceedsPolicy(EgressClass)
    case loopbackDestinationWouldLeaveViaProxy
    case proxyChainUnknown
    case purposeNotAllowed(String)
    /// この送信形に許されないスキーム（ws を HTTP 経路へ、等）
    case schemeNotAllowed(String)
    case insecureSchemeForClass(EgressClass)
    case redirectRefused(from: String, to: String)
    case probeCandidateExpired
}

/// 送信先の到達範囲。数値が大きいほど遠くへ出る。
public enum EgressClass: Int, Comparable, Codable, Sendable, CaseIterable {
    case loopback = 0
    case privateNetwork = 1
    case publicInternet = 2

    public static func < (a: EgressClass, b: EgressClass) -> Bool { a.rawValue < b.rawValue }
}
