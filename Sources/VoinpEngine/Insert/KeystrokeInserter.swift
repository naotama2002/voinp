import CoreGraphics
import Foundation
import VoinpCore

/// キーイベントを合成して 1 文字ずつ入力する。
///
/// **ペーストボードを一切使わない**ので、Universal Clipboard 経由で
/// テキストが他のデバイスへ渡る経路が生じない（docs/06-privacy.md）。
/// 代償として長文では遅く、取り消しも 1 回で戻らない。
public actor KeystrokeInserter: TextInserter {
    public let identifier = "keystroke"

    private let delayMs: Int

    public init(delayMs: Int = 2) {
        self.delayMs = delayMs
    }

    public func insert(_ text: String, into target: InsertionTarget) async throws {
        // ペースト方式と同じ理由で、開始時の判定ではなく直前の実態を見る。
        // こちらは 1 文字ずつ post するぶん、取り違えたときの被害が大きい。
        try await MainActor.run { try InsertionTargetResolver.assertStillCurrent(target) }
        guard !text.isEmpty else { return }

        let source = CGEventSource(stateID: .hidSystemState)

        // UTF-16 で送る。絵文字などのサロゲートペアは分割すると壊れるので、
        // 1 文字（Character）単位でまとめて送る。
        for character in text {
            let utf16 = Array(character.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw VoinpError.accessibilityNotGranted }

            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)

            if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
        }
    }
}
