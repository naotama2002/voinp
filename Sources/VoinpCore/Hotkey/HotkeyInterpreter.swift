import Foundation

/// CGEvent tap から来る生のキーイベント。
public struct RawKeyEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case keyDown, keyUp, flagsChanged }
    public let kind: Kind
    public let keyCode: UInt16
    public let modifiers: Modifiers
    public let isRepeat: Bool

    public init(kind: Kind, keyCode: UInt16, modifiers: Modifiers, isRepeat: Bool = false) {
        self.kind = kind; self.keyCode = keyCode
        self.modifiers = modifiers; self.isRepeat = isRepeat
    }
}

public enum SessionCommand: Equatable, Sendable {
    case start
    case stop
    /// 止めて**挿入せず編集ウィンドウを開く**。
    /// ホットキーに修飾キーを 1 つ足して離すと、これになる。
    case stopAndEdit
    case cancel
}

/// ホットキーの解釈。tap のコールバックから同期的に呼ばれるので、
/// 純粋・高速・非同期処理なしであること。
///
/// 時刻は引数で受け取る（Clock を注入しない）。完全に決定的にテストできる。
public struct HotkeyInterpreter: Sendable {

    public enum Behavior: String, Sendable, Codable {
        case hold      // 押している間だけ録音
        case toggle    // 押して開始、もう一度押して終了
        case hybrid    // 長押しなら hold、短タップなら toggle に latch
    }

    public struct Decision: Equatable, Sendable {
        /// true ならイベントを飲み込む（対象アプリに漏らさない）
        public let suppress: Bool
        public let command: SessionCommand?
        public static let ignore = Decision(suppress: false, command: nil)
    }

    public var combo: KeyCombo
    public var behavior: Behavior
    public var holdThreshold: Duration
    public var doubleTapWindow: Duration
    /// 修飾キー単独の和音が確定するまでの猶予。誤爆を防ぐ。
    public var modifierSettle: Duration

    private var pressedAt: ContinuousClock.Instant?
    private var isRecording = false
    private var latchedToggle = false
    private var lastTapAt: ContinuousClock.Instant?
    /// 押されている間の修飾キーの最大集合。単独和音の判定に使う。
    private var peakModifiers: Modifiers = []

    public init(combo: KeyCombo,
                behavior: Behavior = .hybrid,
                holdThreshold: Duration = .milliseconds(200),
                doubleTapWindow: Duration = .milliseconds(400),
                modifierSettle: Duration = .milliseconds(150)) {
        self.combo = combo
        self.behavior = behavior
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
        self.modifierSettle = modifierSettle
    }

    public mutating func handle(_ e: RawKeyEvent, at now: ContinuousClock.Instant) -> Decision {
        // キーリピートは押しっぱなしの継続。状態を変えない。
        if e.isRepeat { return Decision(suppress: isRecording, command: nil) }

        return combo.isModifierOnly
            ? handleModifierOnly(e, at: now)
            : handleKeyCombo(e, at: now)
    }

    /// 指定より多くの修飾キーが押されているか。**編集ウィンドウを開く合図**。
    ///
    /// **修飾キー単独の和音では使えない。** あちらは押下中に修飾キーが増えると
    /// 「⌘⇧ のような通常のショートカットだった」と解釈して録音を取り消す作りで、
    /// 合図と誤爆防止が同じ操作になってしまう。既定の `ctrl+opt+space` は
    /// キー付きなので影響しない。
    private func hasExtraModifiers(_ e: RawKeyEvent) -> Bool {
        !e.modifiers.sideAgnostic.subtracting(combo.modifiers.sideAgnostic).isEmpty
    }

    // MARK: - 通常のキー + 修飾キー

    private mutating func handleKeyCombo(_ e: RawKeyEvent, at now: ContinuousClock.Instant) -> Decision {
        guard e.keyCode == combo.keyCode else {
            // 対象キー以外。録音中でも素通しする（ユーザーの入力を邪魔しない）。
            return .ignore
        }
        let modsMatch = e.modifiers.sideAgnostic.contains(combo.modifiers.sideAgnostic)

        switch e.kind {
        case .keyDown:
            guard modsMatch else { return .ignore }
            return press(at: now, edit: hasExtraModifiers(e))
        case .keyUp:
            guard pressedAt != nil else { return .ignore }
            return release(at: now, edit: hasExtraModifiers(e))
        case .flagsChanged:
            return .ignore
        }
    }

    // MARK: - 修飾キー単独の和音（右 ⌘ 長押しなど）

    private mutating func handleModifierOnly(_ e: RawKeyEvent, at now: ContinuousClock.Instant) -> Decision {
        guard e.kind == .flagsChanged else {
            // 和音中に他のキーが押されたら、それは通常のショートカット。取り消す。
            if e.kind == .keyDown, pressedAt != nil, !isRecording {
                pressedAt = nil
                peakModifiers = []
            }
            return .ignore
        }

        let target = combo.modifiers
        let nowHeld = e.modifiers.contains(target)

        if nowHeld {
            let newExtra = e.modifiers.subtracting(target).subtracting(peakModifiers)
            peakModifiers.formUnion(e.modifiers)
            if pressedAt == nil { return press(at: now, edit: false) }

            // 押下後に別の修飾キーが加わった → これは ⌘⇧ のような通常のショートカットで、
            // 我々のホットキーではなかった。開始済みの録音を取り消す。
            if !newExtra.isEmpty, isRecording {
                pressedAt = nil
                peakModifiers = []
                isRecording = false
                latchedToggle = false
                return Decision(suppress: false, command: .cancel)
            }
            return Decision(suppress: true, command: nil)
        } else {
            guard pressedAt != nil else { return .ignore }
            // 対象以外の修飾キーも一緒に押されていたなら、通常のショートカットの一部。
            let extra = peakModifiers.subtracting(target)
            peakModifiers = []
            if !extra.isEmpty, !isRecording {
                pressedAt = nil
                return .ignore
            }
            return release(at: now, edit: false)
        }
    }

    // MARK: - 押下 / 解放の共通ロジック

    private mutating func press(at now: ContinuousClock.Instant, edit: Bool) -> Decision {
        pressedAt = now

        if combo.requiresDoubleTap {
            guard let last = lastTapAt, now - last <= doubleTapWindow else {
                return Decision(suppress: true, command: nil)   // 1 打目。まだ開始しない
            }
        }

        switch behavior {
        case .hold:
            return startRecording()
        case .toggle:
            return isRecording ? stopRecording(edit: edit) : startRecording()
        case .hybrid:
            // 押下時点では hold か toggle か判らない。録音は即開始し、
            // 解放時の経過時間で「離したら止める」か「latch する」かを決める。
            if isRecording && latchedToggle { return stopRecording(edit: edit) }
            return startRecording()
        }
    }

    private mutating func release(at now: ContinuousClock.Instant, edit: Bool) -> Decision {
        defer { pressedAt = nil }
        guard let down = pressedAt else { return .ignore }
        let held = now - down
        lastTapAt = now

        if combo.requiresDoubleTap && !isRecording {
            return Decision(suppress: true, command: nil)   // 1 打目の解放
        }

        switch behavior {
        case .hold:
            return isRecording ? stopRecording(edit: edit) : Decision(suppress: true, command: nil)
        case .toggle:
            return Decision(suppress: true, command: nil)   // 解放では何もしない
        case .hybrid:
            if held >= holdThreshold {
                return isRecording ? stopRecording(edit: edit) : Decision(suppress: true, command: nil)
            }
            // 短タップ → トグルに latch。次のタップで止まる。
            latchedToggle = true
            return Decision(suppress: true, command: nil)
        }
    }

    private mutating func startRecording() -> Decision {
        isRecording = true
        latchedToggle = false
        return Decision(suppress: true, command: .start)
    }

    private mutating func stopRecording(edit: Bool) -> Decision {
        isRecording = false
        latchedToggle = false
        return Decision(suppress: true, command: edit ? .stopAndEdit : .stop)
    }

    /// セッションが外部要因（Esc、エラー）で終わったときに状態を戻す。
    public mutating func reset() {
        pressedAt = nil
        isRecording = false
        latchedToggle = false
        peakModifiers = []
    }

    public var isActive: Bool { isRecording }
}
