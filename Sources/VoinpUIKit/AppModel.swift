import AppKit
import ApplicationServices
import CoreGraphics
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
    /// 取得に失敗した理由。ウィザードに出して、黙って止まらないようにする。
    public private(set) var modelDownloadError: String?
    /// 取得を始めてからの経過秒。
    /// 進捗が返らない以上、不定バーだけでは「生きているのか固まったのか」が分からない。
    public private(set) var modelDownloadElapsed: Int = 0
    private var elapsedTimer: Timer?

    public var settings: Settings
    let dependencies: Dependencies

    /// セットアップウィザードを出す。合成ルートから注入する。
    public var presentSetup: (() -> Void)?
    /// 設定ウィンドウを出す。合成ルートから注入する。
    public var presentSettings: (() -> Void)?

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
            inserter: DictationCoordinator.makeInserter(settings))
        coordinator = coord

        tasks.append(Task { [weak self] in
            for await update in coord.updates { self?.apply(update) }
        })

        refreshPermissions()
        Log.session.info("起動時の権限: mic(status=\(Permissions.microphoneStatus.rawValue, privacy: .public)) ax(tap=\(self.hotkey != nil, privacy: .public),preflight=\(CGPreflightPostEventAccess(), privacy: .public),trusted=\(AXIsProcessTrusted(), privacy: .public))")
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
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                refreshPermissions()
                // **セットアップが未完了ならウィザードを出し続ける。**
                // 権限やモデルが欠けているとアプリは何もできないので、
                // メニューから探させるのではなく、こちらから提示する。
                if needsSetup {
                    Log.session.info("アクティブ化: セットアップ未完了のため再提示")
                    presentSetup?()
                }
            }
        }
    }

    /// tap の作成を試みる。**成否がそのまま許可の判定になる。**
    @discardableResult
    private func startHotkeyIfPossible() -> Bool {
        if hotkey != nil { return true }
        guard let combo = KeyCombo(string: settings.hotkey.binding) else {
            // 読めない指定は黙って無視すると「効かない」だけになる。必ず残す。
            Log.hotkey.error("ホットキーの指定を解釈できません: \(self.settings.hotkey.binding, privacy: .public)")
            lastError = "ホットキー『\(settings.hotkey.binding)』を解釈できません"
            return false
        }

        let behavior = HotkeyInterpreter.Behavior(rawValue: settings.hotkey.behavior) ?? .hybrid
        let source = EventTapHotkeySource(config: .init(
            combo: combo, behavior: behavior, holdThresholdMs: settings.hotkey.holdThresholdMs))
        do {
            try source.start()
            hotkey = source
            Log.hotkey.info("ホットキーを登録: \(combo.stringValue, privacy: .public) (\(self.settings.hotkey.behavior, privacy: .public))")
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
        case .feedback(let f):
            FeedbackPlayer.play(f, enabled: settings.audio.playFeedbackSounds)
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
            let axPreflight = CGPreflightPostEventAccess()
            let axTrusted = AXIsProcessTrusted()
            Log.session.info("権限: 不足\(missing.count, privacy: .public)件 mic(status=\(micStatus, privacy: .public)) ax(tap=\(axTap, privacy: .public),preflight=\(axPreflight, privacy: .public),trusted=\(axTrusted, privacy: .public))")
            missingPermissions = missing
        }
    }

    // MARK: - 音声モデル

    public func refreshModelReadiness() async {
        let id = settings.transcription.locale
        let request = TranscriptionRequest(locale: Locale(identifier: id))
        let r = await dependencies.speechProvider.readiness(for: request)
        Log.speech.info("モデル状態: locale=\(id, privacy: .public) readiness=\(String(describing: r), privacy: .public)")
        modelReadiness = r
    }

    public func downloadModel() async {
        guard !isDownloadingModel else { return }
        isDownloadingModel = true
        modelProgress = 0
        hasMeaningfulProgress = false
        modelDownloadError = nil
        modelDownloadElapsed = 0
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.modelDownloadElapsed += 1 }
        }
        defer { isDownloadingModel = false }
        do {
            // **上限時間を設ける。** 失敗や停止でプログレスバーが永遠に回り続けると、
            // ユーザーは何が起きているか分からないまま待たされる（実際にそうなった）。
            try await withThrowingTaskGroup(of: Void.self) { group in
                let provider = dependencies.speechProvider
                let locale = Locale(identifier: settings.transcription.locale)
                group.addTask {
                    try await provider.downloadModel(for: locale) { p in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.modelProgress = p
                            if p > 0 && p < 1 { self.hasMeaningfulProgress = true }
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(600))
                    throw VoinpError.modelAssetsMissing("タイムアウト")
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            Log.speech.error("モデル取得に失敗: \(String(describing: error), privacy: .public)")
            modelDownloadError = Self.describe(error)
            lastError = modelDownloadError
        }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        modelProgress = nil
        await refreshModelReadiness()
        Log.speech.info("取得処理を終了: \(self.modelDownloadElapsed, privacy: .public)秒 readiness=\(String(describing: self.modelReadiness), privacy: .public)")
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

    // MARK: - 設定の更新

    private let configStore = ConfigStore()

    /// 設定を変更して保存し、実行中の各部へ反映する。
    ///
    /// 保存の失敗は握り潰さない。書けないまま UI だけ変わると、
    /// 再起動で戻って原因が分からなくなる。
    public func update(_ mutate: (inout Settings) -> Void) {
        var next = settings
        mutate(&next)
        guard next != settings else { return }

        let hotkeyChanged = next.hotkey != settings.hotkey
        let localeChanged = next.transcription.locale != settings.transcription.locale
        settings = next

        do {
            try configStore.save(next)
        } catch {
            Log.config.error("設定を保存できません: \(String(describing: error), privacy: .public)")
            lastError = "設定を保存できませんでした"
        }

        Task { await coordinator?.update(settings: next) }
        if hotkeyChanged { restartHotkey() }
        if localeChanged { Task { await refreshModelReadiness() } }
    }

    /// ホットキーの設定が変わったら張り直す。
    private func restartHotkey() {
        hotkey?.stop()
        hotkey = nil
        refreshPermissions()   // この中で新しい設定で張り直される
    }

    /// 選べる言語。取得済みかどうかは別途 modelReadiness で示す。
    public var availableLocales: [LocaleChoice] {
        AppleSpeechProvider.commonLocales
    }

    public func openConfigDirectory() {
        let dir = configStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// 明示的に設定画面を開く。メニューの別項目として出す。
    public func openSettings(for p: SessionError.Permission) {
        let pane: Permissions.SettingsPane = switch p {
        case .microphone: .microphone
        case .accessibility: .accessibility
        }
        NSWorkspace.shared.open(pane.url)
    }

    /// 失敗理由をユーザー向けの言葉に直す。
    private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        if ns.localizedDescription.contains("Too many allocated locales") {
            return "同時に扱えるロケール数の上限に達しました。アプリを再起動してください。"
        }
        if case VoinpError.modelAssetsMissing("タイムアウト") = error {
            return "取得に時間がかかりすぎました。ネットワークを確認して再試行してください。"
        }
        return "モデルを取得できませんでした（\(ns.localizedDescription)）"
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
        // 使えない状態で黙って失敗させない。何が足りないかを見せる。
        guard !needsSetup else {
            Log.session.notice("セットアップ未完了のため録音を開始しない")
            presentSetup?()
            return
        }
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
