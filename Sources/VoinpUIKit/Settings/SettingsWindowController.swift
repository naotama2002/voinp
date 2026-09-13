import AppKit
import SwiftUI

/// 設定ウィンドウ。セットアップと同じく AppKit で持つ。
///
/// 開いている間は `.regular` に上げて **⌘Tab と Dock に出す**。
/// システム設定など他アプリへ行って戻ってこられないと使い物にならない。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel
    private let policy: ActivationPolicyController
    private var isOpen = false

    init(model: AppModel, policy: ActivationPolicyController) {
        self.model = model
        self.policy = policy
    }

    func show() {
        if let window {
            if !isOpen { isOpen = true; policy.windowDidOpen() }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            // サイドバーがあるのでリサイズできたほうがよい。
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "Voinp 設定"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: SettingsView(model: model))
        w.delegate = self
        window = w
        isOpen = true
        policy.windowDidOpen()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard isOpen else { return }
            isOpen = false
            policy.windowDidClose()
            // 記録中に閉じられてもホットキーが止まったままにならないよう、
            // 念のため再開を試みる（既に動いていれば何もしない）。
            model.setHotkeyRecording(false)
        }
    }
}
