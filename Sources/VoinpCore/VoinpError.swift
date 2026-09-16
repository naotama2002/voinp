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

    /// 設定ファイルに書く名前。**UI からも使うので `VoinpCore` に置く。**
    /// `VoinpUIKit` は `VoinpNet` を import できない（オフライン版が壊れる）。
    public init?(name: String) {
        switch name {
        case "loopback": self = .loopback
        case "privateNetwork": self = .privateNetwork
        case "publicInternet": self = .publicInternet
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .loopback: "loopback"
        case .privateNetwork: "privateNetwork"
        case .publicInternet: "publicInternet"
        }
    }

    /// 画面に出す言い方。
    public var displayName: String {
        switch self {
        case .loopback: "この Mac の中だけ"
        case .privateNetwork: "社内 LAN まで"
        case .publicInternet: "インターネット経由"
        }
    }
}
