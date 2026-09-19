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

    /// **挿入の直前に、録音開始時と同じ相手が前面にいるかを確かめる。**
    ///
    /// `target` は録音開始時に解決したものだが、キーイベントは
    /// `cghidEventTap` へ post するので、**実際には post した瞬間の最前面アプリ**へ届く。
    /// 認識と LLM 校正の間には数秒あるため、その間にアプリを切り替えたり
    /// パスワード欄をクリックしたりすると、発話内容が意図しない場所へ入る。
    ///
    /// 開始時の判定を信用せず、ここで取り直す:
    /// - いまパスワード欄にフォーカスしている → 中止（ペーストボードにも残さない）
    /// - 相手が変わった → 中止（テキストはペーストボードへ退避し、手動で貼れるようにする）
    public static func assertStillCurrent(_ target: InsertionTarget) throws {
        let now = current()

        guard !now.isSecureInput else {
            Log.insert.notice("挿入中止: 挿入直前にパスワード欄へフォーカスしていた")
            throw VoinpError.secureInputActive
        }

        guard now.bundleIdentifier == target.bundleIdentifier,
              now.processIdentifier == target.processIdentifier
        else {
            Log.insert.notice("挿入中止: フォーカスが移動した \(target.bundleIdentifier ?? "?", privacy: .public) → \(now.bundleIdentifier ?? "?", privacy: .public)")
            throw VoinpError.focusChangedDuringRecognition(
                expected: target.bundleIdentifier, actual: now.bundleIdentifier)
        }
    }

    /// **編集ウィンドウで奪ったフォーカスを挿入先へ返す。**
    ///
    /// 編集面を出すと voinp が最前面になる。そのまま挿入へ進むと
    /// `assertStillCurrent` が「挿入先が変わった」と見て中止するので、
    /// 先にここを通して元アプリを前面へ戻す。
    ///
    /// **`activate()` の成否を信じない。** 戻り値は「要求を出せた」であって
    /// 「前面になった」ではない。実際に最前面になるまで確認する。
    /// 戻らなければ false を返し、呼び出し側がペーストボードへ退避する。
    public static func restoreFocus(
        to target: InsertionTarget,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            Log.insert.notice("フォーカスを戻せない: 挿入先のプロセスが終了している")
            return false
        }
        app.activate()

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Log.insert.notice("フォーカスを戻せない: \(target.bundleIdentifier ?? "?", privacy: .public) が前面にならない")
        return false
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
