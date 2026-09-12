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
    public private(set) var modelReadiness: Readiness?
    public private(set) var isDownloadingModel = false
    /// 進捗が一度でも 0 を超えたか。
    /// Speech の資産ダウンロードは fractionCompleted を返さないことがあり
    /// （実測で 0.0 のまま completed=0/1）、0% のバーが固まって見える。
    /// その場合は不定表示に切り替える。
    public private(set) var hasMeaningfulProgress = false

    public var settings: Settings
    let dependencies: Dependencies

    private var coordinator: DictationCoordinator?
    private var hotkey: EventTapHotkeySource?
    private var hud: HUDPanelController?
    private var tasks: [Task<Void, Never>] = []
    private var activationObserver: (any NSObjectProtocol)?

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
            provider: dependencies.speechProvider,
            inserter: PasteInserter(
                pasteboard: SystemPasteboard(),
                restoreDelayMs: settings.insertion.pasteRestoreDelayMs,
                restoreClipboard: settings.insertion.restoreClipboard,
                overrideKeyCode: settings.insertion.pasteKeyCode))
        coordinator = coord

        tasks.append(Task { [weak self] in
            for await update in coord.updates { self?.apply(update) }
        })

        refreshPermissions()
        Task { await refreshModelReadiness() }

        // 権限はポーリングしない。
        //
        // 許可はユーザーがシステム設定で行うので、戻ってきた瞬間＝
        // **アプリがアクティブになった瞬間**に確認すれば足りる。
        // 判定には event tap の作成という副作用のある操作を含むため、
        // 毎秒回すのは無駄でもある。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refreshPermissions() }
        }
    }

    /// tap の作成を試みる。**成否がそのまま許可の判定になる。**
    @discardableResult
    private func startHotkeyIfPossible() -> Bool {
        if hotkey != nil { return true }
        guard let combo = KeyCombo(string: settings.hotkey.binding) else { return false }

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
            return true
        } catch {
            return false
        }
    }



    // MARK: - 更新の反映（switch 1 つ）

    private func apply(_ update: DictationCoordinator.Update) {
        switch update {
        case .phase(let p):
            phase = p
            if case .failed(let e) = p { lastError = HUDView.message(for: e) }
            if case .idle = p { snapshot = .empty; level = 0; modelProgress = nil }
            updateHUD(for: p)
        case .snapshot(let s):
            snapshot = s
            hud?.refreshLayout()   // テキストが伸びたら高さを追従させる
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

    /// 許可の判定。
    ///
    /// アクセシビリティは `AXIsProcessTrusted()` を見ない。
    /// あのフラグはプロセス内でキャッシュされ、システム設定で許可しても
    /// 再起動するまで false のままになることがある。
    /// **実際に event tap を作れたかどうか**で判定すれば、その問題を回避できる。
    public func refreshPermissions() {
        // 全部揃っていれば何もしない。
        // ホットキーが動いている限りアクセシビリティは効いており、
        // マイクも一度許可されれば実行中に失われることはない。
        if missingPermissions.isEmpty && hotkey != nil { return }

        var missing: [SessionError.Permission] = []
        if !Permissions.isMicrophoneUsable { missing.append(.microphone) }
        if !startHotkeyIfPossible() { missing.append(.accessibility) }
        if missing != missingPermissions {
            // キャッシュされた値と機能判定がずれていないかも記録しておく。
            // ずれていれば「システム設定で許可したが再起動していない」状態。
            let micStatus = Permissions.microphoneStatus.rawValue
            let axTap = hotkey != nil
            Log.session.info("権限: 不足\(missing.count, privacy: .public)件 mic(status=\(micStatus, privacy: .public)) ax(tap=\(axTap, privacy: .public))")
            missingPermissions = missing
        }
    }

    // MARK: - 音声モデル

    public func refreshModelReadiness() async {
        let request = TranscriptionRequest(
            locale: Locale(identifier: settings.transcription.locale))
        modelReadiness = await dependencies.speechProvider.readiness(for: request)
    }

    public func downloadModel() async {
        guard !isDownloadingModel else { return }
        isDownloadingModel = true
        modelProgress = 0
        hasMeaningfulProgress = false
        defer { isDownloadingModel = false }
        do {
            try await dependencies.speechProvider.downloadModel(
                for: Locale(identifier: settings.transcription.locale)
            ) { [weak self] p in
                Task { @MainActor in
                    guard let self else { return }
                    self.modelProgress = p
                    if p > 0 && p < 1 { self.hasMeaningfulProgress = true }
                }
            }
        } catch {
            lastError = "モデルを取得できませんでした"
        }
        modelProgress = nil
        await refreshModelReadiness()
    }

    // MARK: - セットアップ

    /// セットアップが必要か。**状態から導出する**ので、
    /// 後から権限を取り消された場合も自動的にウィザードが出る。
    public var needsSetup: Bool {
        !missingPermissions.isEmpty || modelReadiness != .ready
    }

    /// 一度でも最後まで案内したか。すべて揃っていても初回は使い方を見せたい。
    private static let completedKey = "onboardingCompleted"
    public var hasSeenSetup: Bool {
        get { UserDefaults.standard.bool(forKey: Self.completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.completedKey) }
    }

    /// 初回起動時にウィザードを出すべきか。
    public var shouldPresentSetup: Bool { needsSetup || !hasSeenSetup }

    /// 許可を求める。**OS のダイアログと設定画面を同時に出さない。**
    /// 両方出すと、ダイアログの上に設定が被さって何が起きたのか分からなくなる。
    public func requestPermission(_ p: SessionError.Permission) {
        switch p {
        case .microphone:
            Task {
                switch await Permissions.requestMicrophoneIfPossible() {
                case .granted, .promptShown:
                    // OS のダイアログに任せる。設定は開かない。
                    refreshPermissions()
                case .mustUseSettings:
                    // 拒否済みなのでダイアログは二度と出ない。設定を開くしかない。
                    openSettings(for: .microphone)
                }
            }
        case .accessibility:
            // Apple のダイアログ自体に「システム設定を開く」ボタンが付いている。
            // こちらから重ねて開かない。
            Permissions.requestAccessibility()
            refreshPermissions()
        }
    }

    /// アプリを再起動する。
    ///
    /// tap の作成で判定しているので通常は不要だが、
    /// TCC のキャッシュが残る経路が他にもありうるので確実な逃げ道を残す。
    /// 再起動してもセットアップウィザードに戻ってくる。
    public func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }

    /// 明示的に設定画面を開く。メニューの別項目として出す。
    public func openSettings(for p: SessionError.Permission) {
        let pane: Permissions.SettingsPane = switch p {
        case .microphone: .microphone
        case .accessibility: .accessibility
        }
        NSWorkspace.shared.open(pane.url)
    }

    /// マイクの許可にアプリ再起動が必要な状態か。
    public var microphoneNeedsRestart: Bool {
        missingPermissions.contains(.microphone) && Permissions.microphoneRequiresRestart
    }

    /// 許可の説明文。何をなぜ求めているかを先に伝える。
    public func permissionExplanation(_ p: SessionError.Permission) -> String {
        switch p {
        case .microphone:    "音声を認識するために必要です。音声はこの Mac 上でのみ処理されます。"
        case .accessibility: "ホットキーの検出と、他のアプリへのテキスト挿入に必要です。"
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
