import CoreGraphics
import Foundation
import VoinpCore

/// `CGEvent.tapCreate` で全体ホットキーを取る。
///
/// 機構はこれ一本。Carbon `RegisterEventHotKey` は SDK のヘッダから消えており、
/// そもそもキーアップを配送しないので push-to-talk が作れない。
/// `NSEvent` のグローバルモニタはイベントを抑止できず、ホットキーが対象アプリに漏れる。
///
/// 必要な権限はアクセシビリティのみ。テキスト挿入でどのみち必要なので追加コストはない。
public final class EventTapHotkeySource: @unchecked Sendable {

    public struct Config: Sendable {
        public var combo: KeyCombo
        public var behavior: HotkeyInterpreter.Behavior
        public var holdThresholdMs: Int
        public init(combo: KeyCombo, behavior: HotkeyInterpreter.Behavior, holdThresholdMs: Int) {
            self.combo = combo; self.behavior = behavior; self.holdThresholdMs = holdThresholdMs
        }
    }

    public let commands: AsyncStream<SessionCommand>
    private let continuation: AsyncStream<SessionCommand>.Continuation

    private let lock = NSLock()
    private var interpreter: HotkeyInterpreter

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    public init(config: Config) {
        self.interpreter = HotkeyInterpreter(
            combo: config.combo,
            behavior: config.behavior,
            holdThreshold: .milliseconds(config.holdThresholdMs))
        let parts = AsyncStream<SessionCommand>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.commands = parts.stream
        self.continuation = parts.continuation
    }

    public func updateConfig(_ config: Config) {
        lock.lock(); defer { lock.unlock() }
        interpreter = HotkeyInterpreter(
            combo: config.combo,
            behavior: config.behavior,
            holdThreshold: .milliseconds(config.holdThresholdMs))
    }

    /// セッションが外部要因で終わったときに解釈器の状態を戻す。
    public func resetState() {
        lock.lock(); defer { lock.unlock() }
        interpreter.reset()
    }

    // MARK: - 起動 / 停止

    public func start() throws {
        guard Permissions.isAccessibilityTrusted else {
            throw VoinpError.accessibilityNotGranted
        }
        guard thread == nil else { return }

        // tap のコールバックはイベント配送経路の中で同期的に走る。
        // メインの run loop に載せると、メインが詰まった瞬間に
        // tapDisabledByTimeout でホットキーが死ぬ。専用スレッドに隔離する。
        let t = Thread { [weak self] in self?.runTapLoop() }
        t.name = "voinp.hotkey-tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        if let src = runLoopSource, let rl = threadRunLoop {
            CFRunLoopRemoveSource(rl, src, .commonModes)
            CFRunLoopStop(rl)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil; runLoopSource = nil; threadRunLoop = nil; thread = nil
        continuation.finish()
    }

    private func runTapLoop() {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let machPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,       // システムの Globe キー処理より先に見える
            options: .defaultTap,             // nil を返すとイベントを飲み込める
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<EventTapHotkeySource>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return }

        tap = machPort
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        runLoopSource = src
        let rl = CFRunLoopGetCurrent()
        threadRunLoop = rl
        CFRunLoopAddSource(rl, src, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
        CFRunLoopRun()
    }

    // MARK: - コールバック（非同期処理を一切しない）

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // システムはコールバックが遅いとき、または特定の入力でタップを無効化する。
        // ここで再武装しないと、一度詰まっただけでホットキーが永久に死ぬ。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let kind: RawKeyEvent.Kind?
        switch type {
        case .keyDown:      kind = .keyDown
        case .keyUp:        kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default:            kind = nil
        }
        guard let kind else { return Unmanaged.passUnretained(event) }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let raw = RawKeyEvent(kind: kind, keyCode: keyCode,
                              modifiers: Modifiers(cgFlags: event.flags), isRepeat: isRepeat)

        lock.lock()
        let decision = interpreter.handle(raw, at: .now)
        lock.unlock()

        if let command = decision.command { continuation.yield(command) }
        return decision.suppress ? nil : Unmanaged.passUnretained(event)
    }
}

// MARK: - CGEventFlags → Modifiers

extension Modifiers {
    /// 左右の判別にはデバイス依存ビットを使う。
    /// 公開定数 (`.maskCommand` 等) では「右 ⌘ を押しっぱなし」を表現できない。
    init(cgFlags f: CGEventFlags) {
        var m: Modifiers = []
        let raw = f.rawValue
        if raw & 0x0001 != 0 { m.insert(.leftControl) }   // NX_DEVICELCTLKEYMASK
        if raw & 0x2000 != 0 { m.insert(.rightControl) }  // NX_DEVICERCTLKEYMASK
        if raw & 0x0002 != 0 { m.insert(.leftShift) }     // NX_DEVICELSHIFTKEYMASK
        if raw & 0x0004 != 0 { m.insert(.rightShift) }    // NX_DEVICERSHIFTKEYMASK
        if raw & 0x0020 != 0 { m.insert(.leftOption) }    // NX_DEVICELALTKEYMASK
        if raw & 0x0040 != 0 { m.insert(.rightOption) }   // NX_DEVICERALTKEYMASK
        if raw & 0x0008 != 0 { m.insert(.leftCommand) }   // NX_DEVICELCMDKEYMASK
        if raw & 0x0010 != 0 { m.insert(.rightCommand) }  // NX_DEVICERCMDKEYMASK
        if f.contains(.maskSecondaryFn) { m.insert(.function) }

        // デバイスビットが立たない経路（合成イベント等）へのフォールバック
        if m.isDisjoint(with: .control), f.contains(.maskControl) { m.insert(.leftControl) }
        if m.isDisjoint(with: .shift),   f.contains(.maskShift)   { m.insert(.leftShift) }
        if m.isDisjoint(with: .option),  f.contains(.maskAlternate) { m.insert(.leftOption) }
        if m.isDisjoint(with: .command), f.contains(.maskCommand) { m.insert(.leftCommand) }
        self = m
    }
}
