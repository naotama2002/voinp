import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import VoinpCore

/// ペーストボード + ⌘V 合成による挿入。**既定の戦略。**
///
/// AX の set-value を既定にしないのは、Electron / ターミナル / Xcode で無言で失敗する割合が高く、
/// さらに挿入先アプリの undo 履歴を作らないため。⌘V はほぼ 100% 動き、undo も 1 ステップで済む。
public actor PasteInserter: TextInserter {
    public let identifier = "paste"

    private let pasteboard: any PasteboardProtocol
    private let restoreDelayMs: Int
    private let restoreClipboard: Bool
    private let overrideKeyCode: Int?

    public init(pasteboard: any PasteboardProtocol,
                restoreDelayMs: Int = 250,
                restoreClipboard: Bool = true,
                overrideKeyCode: Int? = nil) {
        self.pasteboard = pasteboard
        self.restoreDelayMs = restoreDelayMs
        self.restoreClipboard = restoreClipboard
        self.overrideKeyCode = overrideKeyCode
    }

    public func insert(_ text: String, into target: InsertionTarget) async throws {
        guard !target.isSecureInput else { throw VoinpError.secureInputActive }
        guard CGPreflightPostEventAccess() else { throw VoinpError.accessibilityNotGranted }

        let saved = await MainActor.run { pasteboard.snapshot() }
        let ours = await MainActor.run { pasteboard.clearAndWrite(text, concealed: true) }

        try postCommandV()

        try? await Task.sleep(for: .milliseconds(restoreDelayMs))

        if restoreClipboard {
            await MainActor.run {
                // 自分が書いた後に誰かが書いていたら復元しない。
                // （ユーザーのコピーやクリップボードマネージャの新しい内容を壊さないため）
                if PasteboardRestorePolicy.shouldRestore(
                    currentChangeCount: pasteboard.changeCount, ourChangeCount: ours) {
                    pasteboard.restore(saved)
                }
            }
        }
    }

    /// ⌘ の down/up を別イベントとして送らない。V のイベントに `.maskCommand` を立てるだけ。
    /// 素の ⌘ keyDown はアプリによってはメニューを開いてしまう。
    private func postCommandV() throws {
        let v = CGKeyCode(overrideKeyCode ?? Self.virtualKeyCodeForV() ?? kVK_ANSI_V)
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        else { throw VoinpError.accessibilityNotGranted }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(8_000)
        up.post(tap: .cghidEventTap)
    }

    /// `kVK_ANSI_V = 0x09` は**物理**キーコードでレイアウト依存。
    /// Dvorak では 0x09 の物理キーは "v" ではないので、現在のレイアウトから逆引きする。
    static func virtualKeyCodeForV() -> Int? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data

        return data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                    UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeys, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) {
                    return code
                }
            }
            return nil
        }
    }
}
