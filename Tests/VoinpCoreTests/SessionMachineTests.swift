import Testing
import Foundation
@testable import VoinpCore

@Suite("SessionMachine")
struct SessionMachineTests {

    let now = ContinuousClock.now
    let target = InsertionTarget(bundleIdentifier: "com.apple.Notes",
                                 processIdentifier: 1, isSecureInput: false)

    private func listening() -> (SessionMachine, ContinuousClock.Instant) {
        var m = SessionMachine()
        let t0 = ContinuousClock.now
        _ = m.handle(.startRequested(target: target), at: t0)
        _ = m.handle(.audioStarted, at: t0)
        return (m, t0)
    }

    @Test("正常系: 開始から挿入まで")
    func happyPath() {
        var (m, t0) = listening()
        #expect(m.phase.isListening)

        let t1 = t0.advanced(by: .seconds(2))
        _ = m.handle(.stopRequested, at: t1)
        #expect(m.phase == .finalizing)

        let actions = m.handle(.transcriptionFinished(text: "こんにちは"), at: t1)
        #expect(m.phase == .refining)
        #expect(actions.contains(.refine("こんにちは")))

        _ = m.handle(.refinementFinished(text: "こんにちは。"), at: t1)
        #expect(m.phase == .awaitingModifierRelease(text: "こんにちは。"))

        let ins = m.handle(.modifiersReleased, at: t1)
        #expect(m.phase == .inserting)
        #expect(ins.contains(.insert("こんにちは。", into: target)))

        _ = m.handle(.insertionFinished(.inserted(strategy: "paste")), at: t1)
        #expect(m.phase == .idle)
    }

    @Test("パスワード欄にフォーカス中は開始しない")
    func refusesSecureInput() {
        var m = SessionMachine()
        let secure = InsertionTarget(bundleIdentifier: "x", processIdentifier: 2, isSecureInput: true)
        _ = m.handle(.startRequested(target: secure), at: now)
        #expect(m.phase == .failed(.secureInputActive))
    }

    @Test("短すぎる録音はキャンセル扱いにして空挿入を防ぐ")
    func tooShortIsCancelled() {
        var (m, t0) = listening()
        _ = m.handle(.stopRequested, at: t0.advanced(by: .milliseconds(100)))
        #expect(m.phase == .failed(.tooShort))
    }

    @Test("セッション中の再開始要求は無視する")
    func neverOverlapsSessions() {
        var (m, t0) = listening()
        let before = m.phase
        let actions = m.handle(.startRequested(target: target), at: t0)
        #expect(m.phase == before)
        #expect(actions == [.play(.error)])
    }

    @Test("空の書き起こしは校正も挿入もしない")
    func emptyTranscriptSkipsEverything() {
        var (m, t0) = listening()
        let t1 = t0.advanced(by: .seconds(2))
        _ = m.handle(.stopRequested, at: t1)
        let actions = m.handle(.transcriptionFinished(text: ""), at: t1)
        #expect(m.phase == .idle)
        #expect(!actions.contains { if case .refine = $0 { true } else { false } })
        #expect(!actions.contains { if case .insert = $0 { true } else { false } })
    }

    @Test("修飾キーが離れないまま時間切れ: 挿入せずペーストボードに退避する")
    func modifierTimeoutNeverInsertsWithWrongModifiers() {
        var (m, t0) = listening()
        let t1 = t0.advanced(by: .seconds(2))
        _ = m.handle(.stopRequested, at: t1)
        _ = m.handle(.transcriptionFinished(text: "本文"), at: t1)
        _ = m.handle(.refinementFinished(text: "本文"), at: t1)

        let actions = m.handle(.modifierWaitTimedOut, at: t1)
        #expect(m.phase == .failed(.modifiersStuck))
        #expect(actions.contains(.copyToPasteboardAsFallback("本文")))
        // ⌃⌥⌘V を送らないことがこのテストの本質
        #expect(!actions.contains { if case .insert = $0 { true } else { false } })
    }

    @Test("挿入に失敗してもテキストは必ずどこかに残る")
    func insertionFailureKeepsText() {
        var (m, t0) = listening()
        let t1 = t0.advanced(by: .seconds(2))
        _ = m.handle(.stopRequested, at: t1)
        _ = m.handle(.transcriptionFinished(text: "本文"), at: t1)
        _ = m.handle(.refinementFinished(text: "本文"), at: t1)
        let actions = m.handle(.failed(.insertionFailed(.axSilentNoop)), at: t1)
        #expect(actions.contains(.copyToPasteboardAsFallback("本文")))
    }

    @Test("失敗状態からは新しいセッションを開始できる")
    func recoversFromFailure() {
        var m = SessionMachine()
        _ = m.handle(.failed(.tooShort), at: now)
        #expect(m.phase == .failed(.tooShort))
        _ = m.handle(.startRequested(target: target), at: now)
        #expect(m.phase == .arming)
    }
}

@Suite("SessionMachine — モデル取得")
struct SessionMachineModelTests {
    let target = InsertionTarget(bundleIdentifier: "x", processIdentifier: 1, isSecureInput: false)

    @Test("モデル未取得なら実際に取得を開始する（進捗表示だけで止まらない）")
    func startsDownloadNotJustProgress() {
        var m = SessionMachine()
        let t = ContinuousClock.now
        _ = m.handle(.startRequested(target: target), at: t)
        let actions = m.handle(.modelProgress(0), at: t)
        #expect(actions.contains(.installModel),
                "phase を変えるだけでは永久にダウンロードが始まらない")
    }

    @Test("取得中の進捗更新では二重に開始しない")
    func doesNotRestartDownload() {
        var m = SessionMachine()
        let t = ContinuousClock.now
        _ = m.handle(.startRequested(target: target), at: t)
        _ = m.handle(.modelProgress(0), at: t)
        let again = m.handle(.modelProgress(0.5), at: t)
        #expect(!again.contains(.installModel))
    }

    @Test("取得完了で録音準備に戻る")
    func readyResumesCapture() {
        var m = SessionMachine()
        let t = ContinuousClock.now
        _ = m.handle(.startRequested(target: target), at: t)
        _ = m.handle(.modelProgress(0), at: t)
        let actions = m.handle(.modelReady, at: t)
        #expect(m.phase == .arming)
        #expect(actions.contains(.startCapture(target)))
    }
}

@Suite("SessionMachine — 挿入失敗時の退避")
struct SessionMachineFallbackTests {
    let target = InsertionTarget(bundleIdentifier: "x", processIdentifier: 1, isSecureInput: false)

    private func upToInserting(_ m: inout SessionMachine, refined: String) {
        let t = ContinuousClock.now
        _ = m.handle(.startRequested(target: target), at: t)
        _ = m.handle(.audioStarted, at: t)
        let t1 = t.advanced(by: .seconds(2))
        _ = m.handle(.stopRequested, at: t1)
        _ = m.handle(.transcriptionFinished(text: "生原稿"), at: t1)
        _ = m.handle(.refinementFinished(text: refined), at: t1)
        _ = m.handle(.modifiersReleased, at: t1)
    }

    @Test("挿入に失敗したら、校正後のテキストを退避する（生原稿ではない）")
    func fallbackUsesRefinedText() {
        var m = SessionMachine()
        upToInserting(&m, refined: "校正後のテキスト。")
        let actions = m.handle(.failed(.insertionFailed(.axSilentNoop)), at: .now)
        #expect(actions.contains(.copyToPasteboardAsFallback("校正後のテキスト。")),
                "buffer.finalText を使うと校正結果を取りこぼす")
    }

    @Test("退避するテキストが空にならない")
    func fallbackNeverEmpty() {
        var m = SessionMachine()
        upToInserting(&m, refined: "何か")
        let actions = m.handle(.failed(.insertionFailed(.axSilentNoop)), at: .now)
        let texts = actions.compactMap { action -> String? in
            if case .copyToPasteboardAsFallback(let t) = action { return t }
            return nil
        }
        #expect(texts.allSatisfy { !$0.isEmpty }, "空文字を貼り付けてはいけない")
    }
}
