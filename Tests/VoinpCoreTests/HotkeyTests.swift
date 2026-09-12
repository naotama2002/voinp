import Testing
import Foundation
@testable import VoinpCore

@Suite("KeyCombo")
struct KeyComboTests {

    @Test("文字列 → KeyCombo → 文字列 の往復", arguments: [
        "ctrl+opt+space", "rightCommand", "fn", "doubleTap:rightCommand", "cmd+escape",
    ])
    func roundTrip(_ s: String) {
        let c = KeyCombo(string: s)
        #expect(c != nil, "パースできること: \(s)")
        #expect(c?.stringValue == s, "往復で一致すること: \(s)")
    }

    @Test("不正な文字列は nil")
    func rejectsGarbage() {
        #expect(KeyCombo(string: "") == nil)
        #expect(KeyCombo(string: "nonsense") == nil)
        #expect(KeyCombo(string: "space+return") == nil)   // 非修飾キーは 1 つまで
    }

    @Test("修飾キー単独かどうか")
    func modifierOnlyDetection() {
        #expect(KeyCombo(string: "rightCommand")?.isModifierOnly == true)
        #expect(KeyCombo(string: "ctrl+opt+space")?.isModifierOnly == false)
    }

    @Test("左右は区別され、sideAgnostic で畳める")
    func sideHandling() {
        let right = KeyCombo(string: "rightCommand")!
        #expect(right.modifiers.contains(.rightCommand))
        #expect(!right.modifiers.contains(.leftCommand))
        #expect(right.modifiers.sideAgnostic == .command)
    }
}

@Suite("HotkeyInterpreter")
struct HotkeyInterpreterTests {

    let combo = KeyCombo(string: "ctrl+opt+space")!
    let mods: Modifiers = [.leftControl, .leftOption]

    private func down(_ i: inout HotkeyInterpreter, _ t: ContinuousClock.Instant) -> HotkeyInterpreter.Decision {
        i.handle(RawKeyEvent(kind: .keyDown, keyCode: 0x31, modifiers: mods), at: t)
    }
    private func up(_ i: inout HotkeyInterpreter, _ t: ContinuousClock.Instant) -> HotkeyInterpreter.Decision {
        i.handle(RawKeyEvent(kind: .keyUp, keyCode: 0x31, modifiers: mods), at: t)
    }

    @Test("hold: 押している間だけ録音")
    func holdMode() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hold)
        let t = ContinuousClock.now
        #expect(down(&i, t).command == .start)
        #expect(up(&i, t.advanced(by: .seconds(2))).command == .stop)
    }

    @Test("toggle: 押して開始、もう一度押して終了。解放では何も起きない")
    func toggleMode() {
        var i = HotkeyInterpreter(combo: combo, behavior: .toggle)
        let t = ContinuousClock.now
        #expect(down(&i, t).command == .start)
        #expect(up(&i, t.advanced(by: .milliseconds(50))).command == nil)
        #expect(down(&i, t.advanced(by: .seconds(5))).command == .stop)
    }

    @Test("hybrid: 長押しは離すと止まる")
    func hybridHold() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hybrid)
        let t = ContinuousClock.now
        #expect(down(&i, t).command == .start)
        #expect(up(&i, t.advanced(by: .milliseconds(800))).command == .stop)
    }

    @Test("hybrid: 短タップはトグルに latch し、次のタップで止まる")
    func hybridToggleLatch() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hybrid)
        let t = ContinuousClock.now
        #expect(down(&i, t).command == .start)
        // 200ms 未満で離す → latch。止まらない。
        #expect(up(&i, t.advanced(by: .milliseconds(80))).command == nil)
        #expect(i.isActive, "latch 中は録音継続")
        // 次のタップで停止
        #expect(down(&i, t.advanced(by: .seconds(3))).command == .stop)
    }

    @Test("ホットキーは対象アプリに漏らさない（suppress される）")
    func suppressesTargetKey() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hold)
        let t = ContinuousClock.now
        #expect(down(&i, t).suppress, "ホットキーを飲み込まないと対象アプリに空白が入る")
    }

    @Test("対象外のキーは素通しする")
    func passesThroughOtherKeys() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hold)
        let d = i.handle(RawKeyEvent(kind: .keyDown, keyCode: 0x00, modifiers: mods),
                         at: ContinuousClock.now)
        #expect(!d.suppress)
        #expect(d.command == nil)
    }

    @Test("修飾キーが足りなければ発動しない")
    func requiresAllModifiers() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hold)
        let d = i.handle(RawKeyEvent(kind: .keyDown, keyCode: 0x31, modifiers: [.leftControl]),
                         at: ContinuousClock.now)
        #expect(d.command == nil)
    }

    @Test("キーリピートで多重開始しない")
    func ignoresKeyRepeat() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hold)
        let t = ContinuousClock.now
        _ = down(&i, t)
        let rep = i.handle(RawKeyEvent(kind: .keyDown, keyCode: 0x31, modifiers: mods, isRepeat: true),
                           at: t.advanced(by: .milliseconds(100)))
        #expect(rep.command == nil)
    }

    // ── 修飾キー単独の和音（右 ⌘ 長押し）──

    @Test("修飾キー単独: 押して開始、離して終了")
    func modifierOnlyHold() {
        var i = HotkeyInterpreter(combo: KeyCombo(string: "rightCommand")!, behavior: .hold)
        let t = ContinuousClock.now
        let d1 = i.handle(RawKeyEvent(kind: .flagsChanged, keyCode: 0x36, modifiers: [.rightCommand]), at: t)
        #expect(d1.command == .start)
        let d2 = i.handle(RawKeyEvent(kind: .flagsChanged, keyCode: 0x36, modifiers: []),
                          at: t.advanced(by: .seconds(1)))
        #expect(d2.command == .stop)
    }

    @Test("修飾キー単独: 他の修飾キーと同時押しなら通常ショートカットとして素通し")
    func modifierOnlyIgnoresChords() {
        var i = HotkeyInterpreter(combo: KeyCombo(string: "rightCommand")!, behavior: .hold)
        let t = ContinuousClock.now
        _ = i.handle(RawKeyEvent(kind: .flagsChanged, keyCode: 0x36, modifiers: [.rightCommand]), at: t)
        // ⌘⇧ の一部だった
        _ = i.handle(RawKeyEvent(kind: .flagsChanged, keyCode: 0x38,
                                 modifiers: [.rightCommand, .leftShift]), at: t.advanced(by: .milliseconds(30)))
        // 別の修飾キーが加わった時点で取り消され、録音は残らない
        #expect(!i.isActive, "⌘⇧ の操作を録音として続行しない")
        let d = i.handle(RawKeyEvent(kind: .flagsChanged, keyCode: 0x36, modifiers: []),
                         at: t.advanced(by: .milliseconds(200)))
        #expect(d.command == nil, "解放時にも stop を出さない")
    }

    @Test("reset で状態が戻る")
    func resetClearsState() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hold)
        _ = down(&i, ContinuousClock.now)
        #expect(i.isActive)
        i.reset()
        #expect(!i.isActive)
    }
}

@Suite("KeyCombo — 実在するキーの往復")
struct KeyComboRealKeyTests {

    @Test("英字キーを含む組み合わせが往復する", arguments: [
        UInt16(0x02),  // D
        UInt16(0x00),  // A
        UInt16(0x11),  // T
        UInt16(0x12),  // 1
    ])
    func letterKeysRoundTrip(_ code: UInt16) {
        let combo = KeyCombo(keyCode: code, modifiers: [.leftControl, .leftOption])
        let s = combo.stringValue
        let parsed = KeyCombo(string: s)
        #expect(parsed != nil, "『\(s)』を読み戻せること")
        #expect(parsed?.keyCode == code, "キーコードが保たれること")
    }
}

@Suite("HotkeyInterpreter — 誤爆しないこと")
struct HotkeyFalsePositiveTests {

    /// 右Shift + fn を登録したとき、別のキーで発動してはいけない。
    private func makeRightShiftFn() -> HotkeyInterpreter {
        let combo = KeyCombo(keyCode: nil, modifiers: [.rightShift, .function])
        return HotkeyInterpreter(combo: combo, behavior: .hybrid)
    }

    @Test("左Shift + fn では発動しない（右Shift を登録している）")
    func leftShiftDoesNotTrigger() {
        var i = makeRightShiftFn()
        let d = i.handle(RawKeyEvent(kind: .flagsChanged, keyCode: 0x38,
                                     modifiers: [.leftShift, .function]), at: .now)
        #expect(d.command == nil, "左右を区別できていない")
    }

    @Test("右Shift + fn で発動する")
    func rightShiftTriggers() {
        var i = makeRightShiftFn()
        let d = i.handle(RawKeyEvent(kind: .flagsChanged, keyCode: 0x3C,
                                     modifiers: [.rightShift, .function]), at: .now)
        #expect(d.command == .start)
    }

    @Test("fn だけでは発動しない")
    func fnAloneDoesNotTrigger() {
        var i = makeRightShiftFn()
        let d = i.handle(RawKeyEvent(kind: .flagsChanged, keyCode: 0x3F,
                                     modifiers: [.function]), at: .now)
        #expect(d.command == nil)
    }

    @Test("無関係な ctrl+opt+space では発動しない")
    func unrelatedComboDoesNotTrigger() {
        var i = makeRightShiftFn()
        let d1 = i.handle(RawKeyEvent(kind: .flagsChanged, keyCode: 0x3B,
                                      modifiers: [.leftControl, .leftOption]), at: .now)
        let d2 = i.handle(RawKeyEvent(kind: .keyDown, keyCode: 0x31,
                                      modifiers: [.leftControl, .leftOption]), at: .now)
        #expect(d1.command == nil)
        #expect(d2.command == nil)
    }
}
