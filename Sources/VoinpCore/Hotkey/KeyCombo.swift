import Foundation

/// 修飾キー。左右を区別する。
///
/// `CGEventFlags` の公開定数 (`.maskCommand` 等) では左右が分からないため、
/// Engine 側でデバイス依存ビット (NX_DEVICEL*/NX_DEVICER*) から変換する。
/// 「右 ⌘ 長押し」をサポートするための非自明な部分。
public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let leftControl  = Modifiers(rawValue: 1 << 0)
    public static let rightControl = Modifiers(rawValue: 1 << 1)
    public static let leftShift    = Modifiers(rawValue: 1 << 2)
    public static let rightShift   = Modifiers(rawValue: 1 << 3)
    public static let leftOption   = Modifiers(rawValue: 1 << 4)
    public static let rightOption  = Modifiers(rawValue: 1 << 5)
    public static let leftCommand  = Modifiers(rawValue: 1 << 6)
    public static let rightCommand = Modifiers(rawValue: 1 << 7)
    public static let function     = Modifiers(rawValue: 1 << 8)

    public static let control: Modifiers = [.leftControl, .rightControl]
    public static let shift:   Modifiers = [.leftShift, .rightShift]
    public static let option:  Modifiers = [.leftOption, .rightOption]
    public static let command: Modifiers = [.leftCommand, .rightCommand]

    /// 左右を畳んだ形。「ctrl+opt」のような左右非依存の指定と比較するのに使う。
    public var sideAgnostic: Modifiers {
        var r: Modifiers = []
        if !isDisjoint(with: .control) { r.formUnion(.control) }
        if !isDisjoint(with: .shift)   { r.formUnion(.shift) }
        if !isDisjoint(with: .option)  { r.formUnion(.option) }
        if !isDisjoint(with: .command) { r.formUnion(.command) }
        if contains(.function)         { r.insert(.function) }
        return r
    }

    public var isEmpty: Bool { rawValue == 0 }
}

/// ホットキーの指定。`keyCode` が nil なら修飾キー単独の和音。
public struct KeyCombo: Hashable, Sendable, Codable {
    public var keyCode: UInt16?
    public var modifiers: Modifiers
    public var requiresDoubleTap: Bool

    public init(keyCode: UInt16?, modifiers: Modifiers, requiresDoubleTap: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.requiresDoubleTap = requiresDoubleTap
    }

    public var isModifierOnly: Bool { keyCode == nil }
}

// MARK: - 文字列表現

extension KeyCombo {
    /// 人が読める形。設定ファイルにはこの形で保存する。
    /// 例: "ctrl+opt+space" / "rightCommand" / "fn" / "doubleTap:rightCommand"
    public var stringValue: String {
        var parts: [String] = []
        // 左右の両方が立っていれば「左右非依存の指定」なので ctrl / opt などに畳む。
        // 片側だけなら leftControl / rightCommand のように側を明示する。
        for (pair, plain, left, right) in Self.modifierNaming {
            let hasLeft = modifiers.contains(left)
            let hasRight = modifiers.contains(right)
            if hasLeft && hasRight {
                parts.append(plain)
            } else if hasLeft {
                parts.append(Self.sidedName(left))
            } else if hasRight {
                parts.append(Self.sidedName(right))
            }
            _ = pair
        }
        if modifiers.contains(.function) { parts.append("fn") }
        if let code = keyCode {
            parts.append(Self.keyNames[code] ?? "key\(code)")
        }
        let body = parts.joined(separator: "+")
        return requiresDoubleTap ? "doubleTap:\(body)" : body
    }

    public init?(string raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var double = false
        if s.hasPrefix("doubleTap:") {
            double = true
            s = String(s.dropFirst("doubleTap:".count))
        }
        guard !s.isEmpty else { return nil }

        var mods: Modifiers = []
        var code: UInt16?
        for token in s.split(separator: "+").map(String.init) {
            let t = token.lowercased()
            if let m = Self.tokenToModifier[t] {
                mods.formUnion(m)
            } else if let c = Self.nameToKey[t] ?? Self.parseNumericKey(t) {
                guard code == nil else { return nil }   // 非修飾キーは 1 つまで
                code = c
            } else {
                return nil
            }
        }
        guard code != nil || !mods.isEmpty else { return nil }
        self.init(keyCode: code, modifiers: mods, requiresDoubleTap: double)
    }

    /// (両側, 左右非依存名, 左, 右) — 出力順がそのまま表示順になる。
    private static let modifierNaming: [(Modifiers, String, Modifiers, Modifiers)] = [
        (.control, "ctrl",  .leftControl, .rightControl),
        (.option,  "opt",   .leftOption,  .rightOption),
        (.shift,   "shift", .leftShift,   .rightShift),
        (.command, "cmd",   .leftCommand, .rightCommand),
    ]

    private static func sidedName(_ m: Modifiers) -> String {
        switch m {
        case .leftControl:  "leftControl"
        case .rightControl: "rightControl"
        case .leftShift:    "leftShift"
        case .rightShift:   "rightShift"
        case .leftOption:   "leftOption"
        case .rightOption:  "rightOption"
        case .leftCommand:  "leftCommand"
        case .rightCommand: "rightCommand"
        default: "?"
        }
    }
    private static let tokenToModifier: [String: Modifiers] = [
        "ctrl": .control, "control": .control, "opt": .option, "option": .option, "alt": .option,
        "shift": .shift, "cmd": .command, "command": .command, "fn": .function,
        "leftcontrol": .leftControl, "rightcontrol": .rightControl,
        "leftshift": .leftShift, "rightshift": .rightShift,
        "leftoption": .leftOption, "rightoption": .rightOption,
        "leftcommand": .leftCommand, "rightcommand": .rightCommand,
    ]
    /// 仮想キーコードと名前の対応（US 配列基準の物理キー位置）。
    ///
    /// **すべてのキーを網羅すること。** 表に無いキーを `key<n>` として書き出すと、
    /// 読み戻せずホットキーが失われる（実際に英字キーで発生した）。
    /// 未知のキーも `key<n>` で往復できるようにしてある。
    public static let keyNames: [UInt16: String] = [
        // 英字
        0x00: "a", 0x0B: "b", 0x08: "c", 0x02: "d", 0x0E: "e", 0x03: "f",
        0x05: "g", 0x04: "h", 0x22: "i", 0x26: "j", 0x28: "k", 0x25: "l",
        0x2E: "m", 0x2D: "n", 0x1F: "o", 0x23: "p", 0x0C: "q", 0x0F: "r",
        0x01: "s", 0x11: "t", 0x20: "u", 0x09: "v", 0x0D: "w", 0x07: "x",
        0x10: "y", 0x06: "z",
        // 数字
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
        0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        // 記号
        0x18: "equal", 0x1B: "minus", 0x21: "leftBracket", 0x1E: "rightBracket",
        0x27: "quote", 0x29: "semicolon", 0x2A: "backslash", 0x2B: "comma",
        0x2C: "slash", 0x2F: "period", 0x32: "grave",
        // 編集・移動
        0x31: "space", 0x24: "return", 0x30: "tab", 0x35: "escape",
        0x33: "delete", 0x75: "forwardDelete",
        0x73: "home", 0x77: "end", 0x74: "pageUp", 0x79: "pageDown",
        0x7B: "left", 0x7C: "right", 0x7D: "down", 0x7E: "up",
        // ファンクション
        0x7A: "f1", 0x78: "f2", 0x63: "f3", 0x76: "f4", 0x60: "f5",
        0x61: "f6", 0x62: "f7", 0x64: "f8", 0x65: "f9", 0x6D: "f10",
        0x67: "f11", 0x6F: "f12", 0x69: "f13", 0x6B: "f14", 0x71: "f15",
    ]

    static let nameToKey: [String: UInt16] =
        Dictionary(uniqueKeysWithValues: keyNames.map { ($1, $0) })

    /// 表に無いキーの "key<n>" 形式を読む。
    static func parseNumericKey(_ token: String) -> UInt16? {
        guard token.hasPrefix("key"), let n = UInt16(token.dropFirst(3)) else { return nil }
        return n
    }
}
