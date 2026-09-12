import AppKit
import Foundation
import Observation
import VoinpCore
import VoinpEngine

/// coordinator の劣化ビュー。格納プロパティは意図的に少なく保つ。
/// `@Published` を 70 個持つ ViewModel を避けるのがこの型の存在理由。
@MainActor @Observable
public final class AppModel {
    public private(set) var phase: SessionPhase = .idle
    public private(set) var snapshot: TranscriptSnapshot = .empty
    public private(set) var level: Float = 0
    public private(set) var missingPermissions: [SessionError.Permission] = []
    public private(set) var modelProgress: Double?
    public private(set) var lastError: String?

    public var settings: Settings
    let dependencies: Dependencies

    private var coordinator: DictationCoordinator?
    private var hotkey: EventTapHotkeySource?
    private var hud: HUDPanelController?
    private var tasks: [Task<Void, Never>] = []
    private var permissionTimer: Timer?

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        self.settings = dependencies.settings
        refreshPermissions()
    }

    // MARK: - 起動

    public func start() {
        hud = HUDPanelController(model: self)

        let coord = DictationCoordinator(
            settings: settings,
            provider: AppleSpeechProvider(),
            inserter: PasteInserter(
                pasteboard: SystemPasteboard(),
                restoreDelayMs: settings.insertion.pasteRestoreDelayMs,
                restoreClipboard: settings.insertion.restoreClipboard,
                overrideKeyCode: settings.insertion.pasteKeyCode))
        coordinator = coord

        tasks.append(Task { [weak self] in
            for await update in coord.updates { self?.apply(update) }
        })

        Log.session.info("起動: 権限不足 \(self.missingPermissions.count, privacy: .public) 件")
        startHotkeyIfPossible()

        // AXIsProcessTrusted はプロセスごとに初回問い合わせ時点でキャッシュされる。
        // 許可された瞬間に反応するようポーリングする（再起動を要求しないため）。
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pollPermissions() }
        }
    }

    private func startHotkeyIfPossible() {
        guard hotkey == nil,
              let combo = KeyCombo(string: settings.hotkey.binding),
              Permissions.isAccessibilityTrusted
        else { return }

        let behavior = HotkeyInterpreter.Behavior(rawValue: settings.hotkey.behavior) ?? .hybrid
        let source = EventTapHotkeySource(config: .init(
            combo: combo, behavior: behavior, holdThresholdMs: settings.hotkey.holdThresholdMs))
        do {
            try source.start()
            hotkey = source
            tasks.append(Task { [weak self] in
                for await command in source.commands {
                    await self?.coordinator?.handle(command: command)
                }
            })
        } catch {
            lastError = "ホットキーを登録できませんでした"
        }
    }

    private func pollPermissions() {
        let before = missingPermissions
        refreshPermissions()
        if before != missingPermissions { startHotkeyIfPossible() }
    }

    // MARK: - 更新の反映（switch 1 つ）

    private func apply(_ update: DictationCoordinator.Update) {
        switch update {
        case .phase(let p):
            phase = p
            if case .failed(let e) = p { lastError = HUDView.message(for: e) }
            if case .idle = p { snapshot = .empty; level = 0; modelProgress = nil }
            updateHUD(for: p)
        case .snapshot(let s): snapshot = s
        case .level(let l): level = l
        case .modelProgress(let p): modelProgress = p
        }
    }

    private func updateHUD(for phase: SessionPhase) {
        switch phase {
        case .idle: hud?.hide()
        default: hud?.show()
        }
    }

    // MARK: - 権限

    public func refreshPermissions() {
        missingPermissions = Permissions.missingPermissions()
    }

    public func requestPermission(_ p: SessionError.Permission) {
        switch p {
        case .microphone:
            Task { _ = await Permissions.requestMicrophone(); refreshPermissions() }
            NSWorkspace.shared.open(Permissions.SettingsPane.microphone.url)
        case .accessibility:
            Permissions.requestAccessibility()
            NSWorkspace.shared.open(Permissions.SettingsPane.accessibility.url)
        }
    }

    // MARK: - メニューから

    public func toggleDictation() {
        Task { await coordinator?.handle(command: phase.isListening ? .stop : .start) }
    }

    public func cancelDictation() {
        hotkey?.resetState()
        Task { await coordinator?.handle(command: .cancel) }
    }

    // MARK: - 表示

    var menuBarSymbol: String {
        if !missingPermissions.isEmpty { return "exclamationmark.triangle" }
        if phase.isListening { return "mic.fill" }
        return settings.privacy.allowNetwork ? "globe" : "mic"
    }

    var privacyHeadline: String {
        if !missingPermissions.isEmpty { return "権限が不足しています" }
        if !settings.privacy.allowNetwork { return "完全ローカル — 送信先なし" }
        if !settings.refinement.enabled { return "完全ローカル — 送信先なし" }
        let host = URL(string: settings.refinement.openaiCompatible.baseURL)?.host ?? "?"
        let op = settings.refinement.openaiCompatible.operatorKind == "self-hosted"
            ? "自社運用と設定" : "外部サービス"
        return "整形テキスト → \(host)（\(op)）"
    }
}
