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
    @State private var isRecording = false
    @State private var monitor: Any?
    /// 押されている修飾キーの最大集合。修飾キー単独の和音を確定するのに使う。
    @State private var peak: Modifiers = []
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
        .onDisappear { stop() }
    }

    private var display: String {
        KeyCombo(string: binding).map { Self.humanize($0) } ?? binding
    }

    private func start() {
        error = nil
        peak = []
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event) ? nil : event    // 記録中はアプリにイベントを渡さない
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        let mods = Modifiers(nsFlags: event.modifierFlags)

        switch event.type {
        case .keyDown:
            if event.keyCode == 0x35 { stop(); return true }   // esc
            commit(KeyCombo(keyCode: event.keyCode, modifiers: mods))
            return true

        case .flagsChanged:
            if mods.isEmpty {
                // すべて離された。非修飾キーが来ていなければ修飾キー単独の和音として確定する。
                if !peak.isEmpty { commit(KeyCombo(keyCode: nil, modifiers: peak)) }
            } else {
                peak.formUnion(mods)
            }
            return true

        default:
            return false
        }
    }

    private func commit(_ combo: KeyCombo) {
        guard let reason = Self.rejection(for: combo) else {
            binding = combo.stringValue
            stop()
            return
        }
        error = reason
        peak = []
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
