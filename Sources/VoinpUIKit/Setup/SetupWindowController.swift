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
final class SetupWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show() {
        if let window {
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
        window = w
        activateAndFront(w)
    }

    func close() {
        window?.orderOut(nil)
    }

    /// アクセサリアプリのウィンドウは activate しないと他のウィンドウの背後に開く。
    private func activateAndFront(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
