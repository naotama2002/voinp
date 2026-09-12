import AppKit
import ApplicationServices
import Foundation
import VoinpCore

/// 挿入先アプリの特定と、パスワード欄かどうかの判定。
public enum InsertionTargetResolver {

    /// AX 呼び出しは相手がハングしていると既定 6 秒ブロックする。必ず絞る。
    private static let messagingTimeout: Float = 0.5

    public static func current() -> InsertionTarget {
        let app = NSWorkspace.shared.frontmostApplication
        return InsertionTarget(
            bundleIdentifier: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier ?? 0,
            isSecureInput: isSecureInputFocused())
    }

    /// `IsSecureEventInputEnabled` は SDK のヘッダから消滅しているので使わない。
    /// AX の subrole を見るほうが精度も高い
    /// （「どこかのプロセスが secure input を主張している」ではなく
    ///  「フォーカス中のフィールドが secure である」が判る）。
    public static func isSecureInputFocused() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused as! AXUIElement?
        else { return false }

        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSubroleAttribute as CFString, &subrole) == .success,
            let s = subrole as? String
        else { return false }

        return s == (kAXSecureTextFieldSubrole as String)
    }
}
