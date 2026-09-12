import AppKit
import SwiftUI
import VoinpCore

/// キーフォーカスを絶対に奪わないパネル。奪うと挿入先を見失う。
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDPanelController {
    private let panel: NonActivatingPanel

    init(model: AppModel) {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)

        panel.isFloatingPanel = true
        panel.level = .floating                 // .statusBar より下
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        // 画面キャプチャ対象から外す「意図」。保証ではない
        // （ヘッダが「一部のシステムサービスに参加できなくなる」と警告している）。
        // 確実に見せたくない場合は ui.hudShowText = false を使う。
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show() {
        reposition()
        // makeKeyAndOrderFront は絶対に使わない。アプリがアクティブになり挿入先を失う。
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    private func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 120))
    }
}
