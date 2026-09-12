import Testing
@testable import VoinpCore

@Suite("修飾キーの追跡")
struct ModifierTrackingTests {

    /// キーレコーダは「押されている修飾キーの集合」を自前で追う。
    /// modifierFlags.isEmpty で判定すると fn などが離してもフラグに残り、
    /// 確定に至らない（右Shift+fn が登録できなかった原因）。
    @Test("複数の修飾キーを押して離すと、すべて離れた時点で空になる")
    func trackPressAndRelease() {
        var held: Modifiers = []
        var peak: Modifiers = []

        // 右Shift を押す
        held.formUnion(.rightShift); peak.formUnion(.rightShift)
        #expect(!held.isEmpty)

        // fn を押す
        held.formUnion(.function); peak.formUnion(.function)
        #expect(peak == [.rightShift, .function])

        // fn を離す
        held.subtract(.function)
        #expect(!held.isEmpty, "まだ右Shift が押されている")

        // 右Shift を離す
        held.subtract(.rightShift)
        #expect(held.isEmpty, "すべて離れた → ここで確定する")
        #expect(peak == [.rightShift, .function], "peak は最大集合を保つ")
    }

    @Test("左右は別のキーとして扱われる")
    func leftAndRightAreDistinct() {
        var held: Modifiers = []
        held.formUnion(.leftShift)
        held.subtract(.rightShift)
        #expect(held.contains(.leftShift), "右を離しても左は残る")
    }
}
