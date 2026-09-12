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
            contentRect: NSRect(x: 0, y: 0, width: HUDView.width, height: 96),
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

        // 認識テキストが伸びると高さも変わるので、内容に合わせてパネルを追従させる。
        let hosting = NSHostingView(rootView: HUDView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        self.hosting = hosting
    }

    private var hosting: NSHostingView<HUDView>?

    func show() {
        resizeToFit()
        reposition()
        // makeKeyAndOrderFront は絶対に使わない。アプリがアクティブになり挿入先を失う。
        panel.orderFrontRegardless()
    }

    /// 認識中は内容が育つので、表示のたびに高さを取り直す。
    func refreshLayout() {
        guard panel.isVisible else { return }
        resizeToFit()
        reposition()
    }

    func hide() { panel.orderOut(nil) }

    private func resizeToFit() {
        guard let hosting else { return }
        let fitting = hosting.fittingSize
        guard fitting.height > 0 else { return }
        panel.setContentSize(NSSize(width: HUDView.width, height: fitting.height))
    }

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
