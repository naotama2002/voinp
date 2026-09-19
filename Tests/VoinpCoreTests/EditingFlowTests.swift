import Testing
import Foundation
@testable import VoinpCore

/// 挿入前に編集する経路。
///
/// 守りたい不変条件は 2 つ。
/// 1. **既定は即挿入のまま**（編集は明示的に要求したときだけ）
/// 2. **編集のあとは必ずフォーカスを戻してから挿入**
///    （voinp が最前面のまま貼ると、自分の編集欄へ入る）
@Suite("挿入前の編集")
struct EditingFlowTests {

    let target = InsertionTarget(bundleIdentifier: "com.apple.Notes",
                                 processIdentifier: 1, isSecureInput: false)

    /// 認識と校正が終わって、挿入の直前まで進んだ状態を作る。
    private func afterRefinement(
        edit: Bool, text: String = "kintone のレコード"
    ) -> (SessionMachine, [SessionAction], ContinuousClock.Instant) {
        var m = SessionMachine()
        let t0 = ContinuousClock.now
        _ = m.handle(.startRequested(target: target), at: t0)
        _ = m.handle(.audioStarted, at: t0)
        let t1 = t0.advanced(by: .seconds(2))
        _ = m.handle(.stopRequested(thenEdit: edit), at: t1)
        _ = m.handle(.transcriptionFinished(text: text), at: t1)
        let actions = m.handle(.refinementFinished(text: text), at: t1)
        return (m, actions, t1)
    }

    // MARK: - 既定は変えない

    @Test("既定の stop では編集ウィンドウを開かず、今までどおり挿入へ進む")
    func defaultStopStillInsertsImmediately() {
        let (m, actions, _) = afterRefinement(edit: false)
        #expect(m.phase == .awaitingModifierRelease(text: "kintone のレコード"))
        #expect(actions.contains(.waitForModifierRelease("kintone のレコード")))
        #expect(!actions.contains(.presentEditor("kintone のレコード")),
                "要求していないのに編集ウィンドウを開かないこと")
    }

    @Test("編集を要求すると編集ウィンドウへ回り、挿入待ちには進まない")
    func editRequestOpensEditor() {
        let (m, actions, _) = afterRefinement(edit: true)
        #expect(m.phase == .editing(text: "kintone のレコード"))
        #expect(actions.contains(.presentEditor("kintone のレコード")))
        #expect(actions.contains(.hideHUD), "HUD と本文を二重に出さないこと")
        #expect(!actions.contains(.waitForModifierRelease("kintone のレコード")))
    }

    // MARK: - フォーカスを戻してから挿入する

    @Test("確定しても即挿入せず、先に挿入先を前面へ戻す")
    func appliedEditRestoresFocusBeforeInserting() {
        var (m, _, t) = afterRefinement(edit: true)

        let applied = m.handle(.editApplied(text: "kintone のレコードを更新"), at: t)
        #expect(m.phase == .restoringFocus(text: "kintone のレコードを更新"))
        #expect(applied.contains(.dismissEditor))
        #expect(applied.contains(.restoreFocus(target)))
        // **ここが本命。** フォーカスを戻す前に挿入すると自分の編集欄へ貼る。
        #expect(!applied.contains(.insert("kintone のレコードを更新", into: target)))
        #expect(!applied.contains(.waitForModifierRelease("kintone のレコードを更新")))

        let restored = m.handle(.focusRestored, at: t)
        #expect(m.phase == .awaitingModifierRelease(text: "kintone のレコードを更新"))
        #expect(restored.contains(.waitForModifierRelease("kintone のレコードを更新")))

        let inserted = m.handle(.modifiersReleased, at: t)
        #expect(inserted.contains(.insert("kintone のレコードを更新", into: target)))
    }

    @Test("フォーカスを戻せなければ挿入せず、本文をペーストボードへ退避する")
    func failedRestoreKeepsTextRecoverable() {
        var (m, _, t) = afterRefinement(edit: true)
        _ = m.handle(.editApplied(text: "直した本文"), at: t)

        let actions = m.handle(
            .failed(.insertionFailed(.focusChangedDuringRecognition(expected: "com.apple.Notes",
                                                                    actual: nil))), at: t)
        #expect(actions.contains(.copyToPasteboardAsFallback("直した本文")),
                "編集した本文は打ち直せない。必ず退避すること")
        #expect(!actions.contains(.insert("直した本文", into: target)))
    }

    // MARK: - 破棄の経路

    @Test("破棄すると挿入せず待機へ戻る")
    func cancelledEditInsertsNothing() {
        var (m, _, t) = afterRefinement(edit: true)
        let actions = m.handle(.editCancelled, at: t)
        #expect(m.phase == .idle)
        #expect(actions.contains(.dismissEditor))
        #expect(!actions.contains(.insert("kintone のレコード", into: target)))
    }

    @Test("全部消して確定したら空文字を貼らない")
    func emptyEditIsTreatedAsCancel() {
        var (m, _, t) = afterRefinement(edit: true)
        let actions = m.handle(.editApplied(text: ""), at: t)
        #expect(m.phase == .idle)
        #expect(!actions.contains(.restoreFocus(target)))
        #expect(!actions.contains(.insert("", into: target)))
    }

    @Test("編集中でも新しいセッションは始まらない")
    func editingDoesNotAcceptNewSession() {
        let (m, _, _) = afterRefinement(edit: true)
        #expect(!m.phase.acceptsNewSession)
    }

    // MARK: - 要求が次へ漏れない

    @Test("編集を要求した次の録音は、要求しなければ即挿入に戻る")
    func editIntentDoesNotLeakToNextSession() {
        var (m, _, t) = afterRefinement(edit: true)
        _ = m.handle(.editApplied(text: "本文"), at: t)
        _ = m.handle(.focusRestored, at: t)
        _ = m.handle(.modifiersReleased, at: t)
        _ = m.handle(.insertionFinished(.inserted(strategy: "paste")), at: t)
        #expect(m.phase == .idle)

        // 2 回目。編集を要求しない。
        let t2 = t.advanced(by: .seconds(10))
        _ = m.handle(.startRequested(target: target), at: t2)
        _ = m.handle(.audioStarted, at: t2)
        let t3 = t2.advanced(by: .seconds(2))
        _ = m.handle(.stopRequested(), at: t3)
        _ = m.handle(.transcriptionFinished(text: "二回目"), at: t3)
        let actions = m.handle(.refinementFinished(text: "二回目"), at: t3)

        #expect(m.phase == .awaitingModifierRelease(text: "二回目"))
        #expect(!actions.contains(.presentEditor("二回目")),
                "前回の編集要求が持ち越されないこと")
    }

    @Test("編集を破棄したあとの録音も即挿入に戻る")
    func cancelAlsoClearsEditIntent() {
        var (m, _, t) = afterRefinement(edit: true)
        _ = m.handle(.editCancelled, at: t)

        let t2 = t.advanced(by: .seconds(10))
        _ = m.handle(.startRequested(target: target), at: t2)
        _ = m.handle(.audioStarted, at: t2)
        let t3 = t2.advanced(by: .seconds(2))
        _ = m.handle(.stopRequested(), at: t3)
        _ = m.handle(.transcriptionFinished(text: "次"), at: t3)
        let actions = m.handle(.refinementFinished(text: "次"), at: t3)
        #expect(!actions.contains(.presentEditor("次")))
    }
}

/// 「止める瞬間の押し方」で編集を要求する部分。
@Suite("編集を要求するホットキー操作")
struct EditGestureTests {

    let combo = KeyCombo(string: "ctrl+opt+space")!
    let plain: Modifiers = [.leftControl, .leftOption]
    let withShift: Modifiers = [.leftControl, .leftOption, .leftShift]

    private func event(_ kind: RawKeyEvent.Kind, _ mods: Modifiers) -> RawKeyEvent {
        RawKeyEvent(kind: kind, keyCode: 0x31, modifiers: mods)
    }

    @Test("いつもどおり離せば stop（即挿入）")
    func plainReleaseStops() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hold)
        let t = ContinuousClock.now
        #expect(i.handle(event(.keyDown, plain), at: t).command == .start)
        #expect(i.handle(event(.keyUp, plain), at: t.advanced(by: .seconds(2))).command == .stop)
    }

    @Test("⇧ を添えて離すと stopAndEdit")
    func shiftReleaseRequestsEdit() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hold)
        let t = ContinuousClock.now
        #expect(i.handle(event(.keyDown, plain), at: t).command == .start)
        #expect(i.handle(event(.keyUp, withShift), at: t.advanced(by: .seconds(2))).command
                == .stopAndEdit)
    }

    @Test("押し始めに ⇧ があっても、離すときに無ければ即挿入")
    func intentIsDecidedAtRelease() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hold)
        let t = ContinuousClock.now
        #expect(i.handle(event(.keyDown, withShift), at: t).command == .start)
        // 離す瞬間に ⇧ を放していた → 編集しない
        #expect(i.handle(event(.keyUp, plain), at: t.advanced(by: .seconds(2))).command == .stop)
    }

    @Test("hybrid の latch でも、止めるタップに ⇧ を添えれば編集になる")
    func latchedToggleHonorsGesture() {
        var i = HotkeyInterpreter(combo: combo, behavior: .hybrid)
        let t = ContinuousClock.now
        #expect(i.handle(event(.keyDown, plain), at: t).command == .start)
        #expect(i.handle(event(.keyUp, plain), at: t.advanced(by: .milliseconds(80))).command == nil)
        #expect(i.isActive, "短タップは latch して録音継続")
        #expect(i.handle(event(.keyDown, withShift), at: t.advanced(by: .seconds(3))).command
                == .stopAndEdit)
    }

    @Test("toggle でも止めるタップの押し方で決まる")
    func toggleHonorsGesture() {
        var i = HotkeyInterpreter(combo: combo, behavior: .toggle)
        let t = ContinuousClock.now
        #expect(i.handle(event(.keyDown, plain), at: t).command == .start)
        _ = i.handle(event(.keyUp, plain), at: t.advanced(by: .milliseconds(50)))
        #expect(i.handle(event(.keyDown, withShift), at: t.advanced(by: .seconds(5))).command
                == .stopAndEdit)
    }
}
