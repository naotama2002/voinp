import AppKit
import SwiftUI
import VoinpCore

/// ホットキーを「押して登録」するフィールド。
///
/// 記録には `NSEvent` の **local monitor** を使う。CGEvent tap は使わない。
/// キーの登録はオンボーディングの一部で、
/// **アクセシビリティ権限を得る前に行えなければならない**（local monitor なら権限不要）。
struct KeyRecorderView: View {
    @Binding var binding: String
    /// 記録の開始・終了を知らせる。既存ホットキーの一時停止に使う。
    var onRecordingChanged: (Bool) -> Void = { _ in }
    @State private var isRecording = false
    @State private var monitor: Any?
    /// 押されている修飾キーの最大集合。修飾キー単独の和音を確定するのに使う。
    @State private var peak: Modifiers = []
    /// いま実際に押されている修飾キー。すべて離れた時点で確定する。
    @State private var held: Modifiers = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    isRecording ? stop() : start()
                } label: {
                    Text(isRecording ? "キーを押してください…" : display)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minWidth: 180)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)

                if isRecording {
                    Text("esc で中止").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        // 記録中にウィンドウを閉じる / タブを移ると、
        // ホットキーが止まったままになる。必ず戻す。
        .onDisappear { stop() }
    }

    private var display: String {
        KeyCombo(string: binding).map { Self.humanize($0) } ?? binding
    }

    private func start() {
        error = nil
        peak = []
        held = []
        isRecording = true
        // 記録中は既存のホットキーを止める。
        // 止めないと、設定しようとしたキーで録音が始まってしまう。
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event) ? nil : event    // 記録中はアプリにイベントを渡さない
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        peak = []
        held = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // 記録を終えたら（確定・中止どちらでも）ホットキーを元に戻す。
        onRecordingChanged(false)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }

        switch event.type {
        case .keyDown:
            if event.keyCode == 0x35 { stop(); return true }   // esc
            // 非修飾キーとの組み合わせでは、押されている修飾キーの
            // 左右を個別に追えないので peak（flagsChanged で集めたもの）を優先する。
            let mods = peak.isEmpty ? Modifiers(nsFlags: event.modifierFlags) : peak
            commit(KeyCombo(keyCode: event.keyCode, modifiers: mods))
            return true

        case .flagsChanged:
            // **左右の判別は keyCode で行う。**
            // NSEvent.ModifierFlags は左右を区別しないため、
            // フラグだけ見ると右 Shift が左として記録される。
            guard let key = Modifiers.fromModifierKeyCode(event.keyCode) else { return true }

            // **押下/解放は自分で追跡する。**
            // modifierFlags.isEmpty で「すべて離された」を判定していたが、
            // fn などは離してもフラグが残ることがあり、確定に至らなかった。
            // そのキーのフラグが立っているかで押下か解放かを判断する。
            if isPressed(key, in: event.modifierFlags) {
                peak.formUnion(key)
                held.formUnion(key)
            } else {
                held.subtract(key)
                // すべて離れたら、修飾キー単独の和音として確定する。
                if held.isEmpty, !peak.isEmpty {
                    commit(KeyCombo(keyCode: nil, modifiers: peak))
                }
            }
            return true

        default:
            return false
        }
    }

    private func commit(_ raw: KeyCombo) {
        // **非修飾キーとの組み合わせでは左右を固定しない。**
        // 「⌃⌥Space」を登録した人は、右の ⌃⌥ でも動くことを期待する。
        // 左右の区別が意味を持つのは「右 ⌘ 長押し」のような
        // 修飾キー単独の和音だけなので、そのときだけ側を保つ。
        let combo = raw.isModifierOnly
            ? raw
            : KeyCombo(keyCode: raw.keyCode,
                       modifiers: raw.modifiers.sideAgnostic,
                       requiresDoubleTap: raw.requiresDoubleTap)

        if let reason = Self.rejection(for: combo) {
            error = reason
            peak = []
            held = []
            return
        }
        binding = combo.stringValue
        stop()
    }

    /// そのキーがいま押されているか。
    /// `flagsChanged` は押下と解放の両方で飛んでくるので、フラグで区別する。
    private func isPressed(_ key: Modifiers, in flags: NSEvent.ModifierFlags) -> Bool {
        if !key.isDisjoint(with: .control) { return flags.contains(.control) }
        if !key.isDisjoint(with: .shift)   { return flags.contains(.shift) }
        if !key.isDisjoint(with: .option)  { return flags.contains(.option) }
        if !key.isDisjoint(with: .command) { return flags.contains(.command) }
        if key.contains(.function)         { return flags.contains(.function) }
        return false
    }

    /// 使わせてはいけない組み合わせ。
    private static func rejection(for combo: KeyCombo) -> String? {
        if combo.modifiers.isEmpty, combo.keyCode != nil {
            return "修飾キーと組み合わせてください（単独キーは通常の入力を奪います）"
        }
        if combo.isModifierOnly, combo.modifiers.sideAgnostic == .command {
            return "⌘ 単独は他のショートカットと衝突します"
        }
        return nil
    }

    private static func humanize(_ c: KeyCombo) -> String {
        var s = ""
        let m = c.modifiers
        if !m.isDisjoint(with: .control) { s += "⌃" }
        if !m.isDisjoint(with: .option)  { s += "⌥" }
        if !m.isDisjoint(with: .shift)   { s += "⇧" }
        if !m.isDisjoint(with: .command) { s += "⌘" }
        if m.contains(.function)         { s += "fn" }
        if let code = c.keyCode {
            s += KeyCombo.keyNames[code].map { " " + $0 } ?? " key\(code)"
        } else {
            // 修飾キー単独は左右を明示したほうが分かりやすい
            s += m.contains(.rightCommand) ? "（右）" : m.contains(.leftCommand) ? "（左）" : ""
        }
        return s.isEmpty ? c.stringValue : s
    }
}

extension Modifiers {
    /// 修飾キーの仮想キーコード。
    /// `NSEvent.ModifierFlags` は左右を区別しないので、
    /// `flagsChanged` の keyCode を見て判定する必要がある。
    static func fromModifierKeyCode(_ keyCode: UInt16) -> Modifiers? {
        switch keyCode {
        case 0x3B: .leftControl
        case 0x3E: .rightControl
        case 0x38: .leftShift
        case 0x3C: .rightShift
        case 0x3A: .leftOption
        case 0x3D: .rightOption
        case 0x37: .leftCommand
        case 0x36: .rightCommand
        case 0x3F: .function
        default: nil
        }
    }

    /// 左右が判らない場合のフォールバック（keyDown 時の修飾キー状態など）。
    /// **`flagsChanged` ではこちらを使わない。** 右 Shift が左として記録される。
    init(nsFlags f: NSEvent.ModifierFlags) {
        var m: Modifiers = []
        if f.contains(.control)  { m.insert(.leftControl) }
        if f.contains(.shift)    { m.insert(.leftShift) }
        if f.contains(.option)   { m.insert(.leftOption) }
        if f.contains(.command)  { m.insert(.leftCommand) }
        if f.contains(.function) { m.insert(.function) }
        self = m
    }
}
