import AppKit
import SwiftUI

/// セットアップウィンドウを AppKit で直接管理する。
///
/// SwiftUI の `Window` シーン + `openWindow` は、
/// 「開く関数を誰がいつ受け取るか」が循環しやすい
/// （`onAppear` で渡すと、ウィンドウが開いてからでないと渡せない）。
/// アクセサリアプリでは出すタイミングをこちらが完全に決めたいので、
/// HUD と同じく NSWindow を自分で持つ。
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
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
            activateAndFront(window)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Voinp のセットアップ"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: SetupView(model: model, onFinish: { [weak self] in
            self?.close()
        }))
        w.delegate = self
        window = w
        isOpen = true
        policy.windowDidOpen()
        activateAndFront(w)
    }

    func close() {
        window?.orderOut(nil)
        windowDidClose()
    }

    /// 閉じるボタンで閉じられた場合もここを通る。
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { windowDidClose() }
    }

    private func windowDidClose() {
        guard isOpen else { return }
        isOpen = false
        policy.windowDidClose()
    }

    /// アクセサリアプリのウィンドウは activate しないと他のウィンドウの背後に開く。
    private func activateAndFront(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
