import AppKit
import Observation
import SwiftUI

/// 編集ウィンドウ。**ここだけ voinp がキーフォーカスを取る。**
///
/// ## `.regular` へ上げない
///
/// 設定やセットアップのウィンドウは `ActivationPolicyController` で
/// `.regular` に上げている（⌘Tab で戻ってこられるように）。
/// 編集ウィンドウでは上げない。上げると Dock アイコンが一瞬現れて消え、
/// 1 回数秒の操作には目障りすぎる。
/// `.accessory` のままでも `NSApp.activate()` でキーウィンドウは持てる。
///
/// ## 確定時は先に閉じる
///
/// 閉じるのと挿入先を前面に戻すのが競ると、**自分の編集欄へ貼る**。
/// 通知を出す前に必ず `dismiss()` する。
@MainActor
final class EditWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let content = EditContent()
    /// 表示中か。赤ボタンで閉じられたときだけ破棄を通知するための番人。
    private var isShowing = false

    var onApply: ((String) -> Void)?
    var onCancel: (() -> Void)?

    func show(text: String, destination: String?) {
        content.text = text
        content.destination = destination

        let w = window ?? makeWindow()
        window = w
        isShowing = true
        place(w)
        // accessory のままでもキーウィンドウは持てる。Dock には出ない。
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// 通知を伴わずに引っ込める。`orderOut` は `windowWillClose` を呼ばない。
    func dismiss() {
        isShowing = false
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        w.title = "挿入前に確認"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: EditView(
            content: content,
            onApply: { [weak self] value in
                guard let self else { return }
                dismiss()               // 先に引っ込める。閉じる前に挿入させない
                onApply?(value)
            },
            onCancel: { [weak self] in
                guard let self else { return }
                dismiss()
                onCancel?()
            }))
        w.delegate = self
        return w
    }

    /// HUD と同じく、マウスのある画面の中央下寄りに出す。
    private func place(_ w: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = w.frame.size
        w.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                 y: frame.minY + 120))
    }

    /// 赤ボタンで閉じられた場合も破棄として扱う。
    /// ここを拾わないと状態機械が `editing` のまま止まり、
    /// **次の音声入力が一切始まらなくなる**（`acceptsNewSession` が false）。
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard isShowing else { return }
            isShowing = false
            onCancel?()
        }
    }
}

/// 編集中の内容。
///
/// **`@State` では足りない。** ウィンドウを使い回すので、開くたびに
/// 外から初期値を差し替える必要がある。`@Observable` にして
/// `Binding` 越しに読み書きさせる。
@MainActor @Observable
final class EditContent {
    var text = ""
    var destination: String?
}
