import AppKit

/// ウィンドウを開いている間だけ通常アプリとして振る舞う。
///
/// `LSUIElement`（= `.accessory`）のアプリは **Dock にも ⌘Tab にも出ない**。
/// ふだんはそれでよいが、設定やセットアップのウィンドウを開いている間は困る。
/// システム設定など他のアプリへ行って戻ろうとしても、
/// ⌘Tab に現れないのでウィンドウ一覧から探す羽目になる（実際にそうなった）。
///
/// ウィンドウがある間だけ `.regular` にして、閉じたら `.accessory` に戻す。
@MainActor
final class ActivationPolicyController {
    private var openWindowCount = 0

    /// ウィンドウを開いたとき。⌘Tab と Dock に現れるようになる。
    func windowDidOpen() {
        openWindowCount += 1
        apply()
    }

    /// ウィンドウを閉じたとき。最後の 1 枚が閉じたらメニューバー常駐に戻る。
    func windowDidClose() {
        openWindowCount = max(0, openWindowCount - 1)
        apply()
    }

    private func apply() {
        let policy: NSApplication.ActivationPolicy = openWindowCount > 0 ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // .regular に上げた直後は自分をアクティブにしないと背面のままになる。
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
}
