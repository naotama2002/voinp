import CoreGraphics
import Foundation
import VoinpCore

/// セッションの唯一の真実。`SessionMachine` を所有し、各ポートを駆動する。
/// UI にはスロットルした snapshot だけを流す（@Published を 70 個持つ ViewModel を避ける）。
public actor DictationCoordinator {

    public enum Update: Sendable {
        case phase(SessionPhase)
        /// 挿入が確定したテキスト。HUD をこれで置き換える。
        /// 認識中の暫定結果と最終結果は食い違うことがあるため、
        /// 「画面に出ていた文字列」と「入力された文字列」がずれないようにする。
        case finalText(String)
        /// 認識結果と校正結果の対。比較表示に使う。
        /// **実行したかどうかも渡す。** 「変更なし」だけでは
        /// LLM が何もしなかったのか、そもそも呼ばれなかったのか区別できない。
        case refinementResult(recognized: String, refined: String, ran: Bool, note: String?)
        case snapshot(TranscriptSnapshot)
        /// 編集ウィンドウを開く。UI 側がキーフォーカスを取る**唯一の合図**。
        case presentEditor(String)
        case dismissEditor
        case level(Float)
        case modelProgress(Double)
        case feedback(Feedback)
    }

    public nonisolated let updates: AsyncStream<Update>
    private nonisolated let updateContinuation: AsyncStream<Update>.Continuation

    private var machine: SessionMachine
    /// 上限時間で自動確定するためのタイマ。
    private var maxDurationTask: Task<Void, Never>?
    private var buffer = TranscriptBuffer()
    private var settings: Settings

    private let provider: any TranscriptionProvider
    /// 設定で切り替わるので固定しない。
    private var inserter: any TextInserter
    private let capture = AudioCapture()
    private let refine: @Sendable (String) async -> RefineOutcome

    private var session: (any TranscriptionSession)?
    private var pumpTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    /// セッションの世代。**開始とキャンセルのたびに進める。**
    ///
    /// `startCapture` はモデル準備・セッション開始・音声取り込みで何度も await する。
    /// actor はその中断点で他のメッセージを受けるので、待っている間に HUD から
    /// キャンセルされ、状態機械が idle に戻ることがある。
    /// 以前はその後も処理が続き、**キャンセル済みなのに録音が始まっていた**。
    /// 中断から戻るたびに世代を照合し、変わっていれば後始末して降りる。
    private var generation: UInt64 = 0
    private var lastLevelEmit = ContinuousClock.now
    private var levelEmitCount = 0

    public init(settings: Settings,
                provider: any TranscriptionProvider,
                inserter: any TextInserter,
                refine: @escaping @Sendable (String) async -> RefineOutcome = { RefineOutcome(text: $0, ran: false, note: "校正が設定されていません") }) {
        self.settings = settings
        self.provider = provider
        self.inserter = inserter
        self.refine = refine
        self.machine = SessionMachine(limits: Self.limits(from: settings))
        // 音量は 20Hz で流れるので、phase や snapshot と同じ流れに乗せると
        // bufferingNewest で捨てられやすい。多めに確保する。
        let parts = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.updates = parts.stream
        self.updateContinuation = parts.continuation
    }

    public func update(settings: Settings) {
        let strategyChanged = settings.insertion != self.settings.insertion
        let limitsChanged = settings.audio.minRecordingMs != self.settings.audio.minRecordingMs
        self.settings = settings
        // 状態機械は待機中にだけ作り直す。録音中に差し替えると進行中の
        // セッションの状態（開始時刻・バッファ）が消える。
        if limitsChanged, case .idle = machine.phase {
            machine = SessionMachine(limits: Self.limits(from: settings))
        }
        // 挿入方法の設定は作り直さないと反映されない。
        if strategyChanged {
            let next = settings
            Task { @MainActor in
                let made = Self.makeInserter(next)
                await self.replaceInserter(made)
            }
        }
    }

    /// 設定から挿入方法を組み立てる。
    /// `SystemPasteboard` が `@MainActor` なので main actor 上で呼ぶ。
    @MainActor
    public static func makeInserter(_ settings: Settings) -> any TextInserter {
        switch settings.insertion.strategy {
        case "keystroke":
            return KeystrokeInserter()
        default:
            return PasteInserter(
                pasteboard: SystemPasteboard(),
                restoreDelayMs: settings.insertion.pasteRestoreDelayMs,
                restoreClipboard: settings.insertion.restoreClipboard,
                overrideKeyCode: settings.insertion.pasteKeyCode)
        }
    }

    // MARK: - 外部からの入口

    private func replaceInserter(_ new: any TextInserter) {
        inserter = new
        Log.insert.info("挿入方法を変更: \(new.identifier, privacy: .public)")
    }

    /// 遷移をテストから読むための口。`@testable` 専用で、公開 API ではない。
    var phaseForTesting: SessionPhase { machine.phase }

    public func handle(command: SessionCommand) async {
        switch command {
        case .start:
            let target = await MainActor.run { InsertionTargetResolver.current() }
            await dispatch(.startRequested(target: target))
        case .stop:
            await dispatch(.stopRequested(thenEdit: false))
        case .stopAndEdit:
            await dispatch(.stopRequested(thenEdit: true))
        case .cancel:
            await dispatch(.cancelRequested)
        }
    }

    /// 編集ウィンドウで確定した。UI から呼ぶ。
    public func applyEdit(_ text: String) async {
        await dispatch(.editApplied(text: text))
    }

    /// 編集ウィンドウを破棄した。UI から呼ぶ。
    public func cancelEdit() async {
        await dispatch(.editCancelled)
    }

    // MARK: - 状態機械の駆動

    private func dispatch(_ event: SessionEvent) async {
        let before = machine.phase
        let actions = machine.handle(event, at: .now)
        if machine.phase != before {
            // logDescription は本文を含まない。String(describing:) を使ってはいけない。
            Log.session.info("phase \(before.logDescription, privacy: .public) -> \(self.machine.phase.logDescription, privacy: .public)")
        }
        updateContinuation.yield(.phase(machine.phase))
        for action in actions { await perform(action) }
    }

    /// 上限時間に達したら自動で確定する。
    ///
    /// `maxRecordingSeconds` は設定ファイルにもUIにもあったのに、
    /// **どこからも参照されていなかった**。トグル方式で録音したまま
    /// 忘れると、無期限にマイクが開き続けることになる。
    /// キャンセルではなく確定にするのは、それまでの発話を捨てないため。
    private func armMaxDuration(generation g: UInt64) {
        maxDurationTask?.cancel()
        let seconds = settings.audio.maxRecordingSeconds
        guard seconds > 0 else { return }   // 0 以下は無制限の意
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.maxDurationReached(generation: g)
        }
    }

    private func maxDurationReached(generation g: UInt64) async {
        // 同じ録音がまだ続いているときだけ効かせる。
        guard isCurrent(g), case .listening = machine.phase else { return }
        Log.session.notice("上限 \(self.settings.audio.maxRecordingSeconds, privacy: .public) 秒に達したので確定する")
        // 自動確定では編集ウィンドウを開かない。ユーザーは画面を見ていない可能性がある。
        await dispatch(.stopRequested(thenEdit: false))
    }

    /// 設定を状態機械の制約へ写す。
    ///
    /// `minRecordingMs` は長らく設定ファイルに書けるだけで、
    /// 状態機械は固定値 250ms を使っていた（設定しても効かなかった）。
    static func limits(from settings: Settings) -> SessionMachine.Limits {
        var limits = SessionMachine.Limits()
        limits.minRecording = .milliseconds(settings.audio.minRecordingMs)
        return limits
    }

    /// 新しい世代を開始し、その番号を返す。
    private func beginGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// `await` から戻ったときに、まだ自分の世代かを確かめる。
    private func isCurrent(_ g: UInt64) -> Bool { generation == g }

    private func perform(_ action: SessionAction) async {
        switch action {
        case .startCapture(let target):
            await startCapture(target: target)

        case .stopCaptureAndFinalize:
            maxDurationTask?.cancel()
            maxDurationTask = nil
            await capture.stop()
            pumpTask?.cancel()
            do {
                try await session?.finish()
            } catch {
                await dispatch(.failed(.transcriptionFailed(.transcriberUnavailable)))
                return
            }
            // **イベントの適用が終わるまで待つ。**
            // finish() の直後に buffer を読むと、確定結果の適用が間に合わず空になる。
            await resultTask?.value
            let text = buffer.bestEffortText
            Log.session.info("確定テキスト \(text.count, privacy: .public) 文字")
            // 暫定結果と確定結果は食い違うことがある
            // （「今日は」と出たあと確定で「公共は」になる等）。
            // 画面を確定結果で置き換えて、見えているものと入るものを一致させる。
            updateContinuation.yield(.finalText(text))
            await dispatch(.transcriptionFinished(text: text))

        case .abortEverything:
            // **最初に世代を進める。** これで、いま中断点で待っている
            // startCapture / refine が再開しても自分が失効したと分かる。
            _ = beginGeneration()
            maxDurationTask?.cancel()
            maxDurationTask = nil
            await capture.stop()
            pumpTask?.cancel()
            resultTask?.cancel()
            await session?.cancel()
            session = nil

        case .refine(let text):
            guard settings.refinement.enabled else {
                Log.refine.info("校正: 設定で無効")
                updateContinuation.yield(.refinementResult(
                    recognized: text, refined: text, ran: false, note: "設定で無効"))
                await dispatch(.refinementFinished(text: text)); return
            }
            // 校正は失敗しても生原稿が返る。ここで分岐は要らない。
            // ただし LLM の応答待ちは数秒あり、その間にキャンセルされうる。
            let g = generation
            let outcome = await refine(text)
            guard isCurrent(g) else {
                Log.refine.info("校正の応答待ちの間にキャンセルされたため破棄する")
                return
            }
            // 本文は出さない（privacy）。変化の有無と量だけ残す。
            if !outcome.ran {
                Log.refine.notice("校正: 実行されず（\(outcome.note ?? "理由不明", privacy: .public)）")
            } else if outcome.text == text {
                Log.refine.info("校正: 実行したが変化なし（\(text.count, privacy: .public) 文字）")
            } else {
                Log.refine.info("校正: \(text.count, privacy: .public) → \(outcome.text.count, privacy: .public) 文字")
            }
            // 実際に挿入する文字列を HUD に反映する。
            updateContinuation.yield(.refinementResult(
                recognized: text, refined: outcome.text, ran: outcome.ran, note: outcome.note))
            updateContinuation.yield(.finalText(outcome.text))
            await dispatch(.refinementFinished(text: outcome.text))

        case .presentEditor(let text):
            updateContinuation.yield(.presentEditor(text))

        case .dismissEditor:
            updateContinuation.yield(.dismissEditor)

        case .restoreFocus(let target):
            // 編集で voinp が最前面になっている。戻せないまま挿入へ進むと
            // **自分の編集ウィンドウへ貼る**ので、戻るまで待つ。
            guard await InsertionTargetResolver.restoreFocus(to: target) else {
                await dispatch(.failed(.insertionFailed(
                    .focusChangedDuringRecognition(expected: target.bundleIdentifier,
                                                   actual: nil))))
                return
            }
            await dispatch(.focusRestored)

        case .waitForModifierRelease(let text):
            await waitForModifierRelease(text: text)

        case .insert(let text, let target):
            do {
                try await inserter.insert(text, into: target)
                await dispatch(.insertionFinished(.inserted(strategy: inserter.identifier)))
            } catch VoinpError.secureInputActive {
                // **ペーストボードにも残さない。** パスワード欄へ向けて話した内容が
                // 退避先から読み出せてしまうのは、挿入できないことより悪い。
                await dispatch(.failed(.secureInputActive))
            } catch let e as VoinpError {
                Log.insert.error("挿入に失敗: \(String(describing: e), privacy: .public)")
                await dispatch(.failed(.insertionFailed(e)))
            } catch {
                Log.insert.error("挿入に失敗: \(String(describing: error), privacy: .public)")
                await dispatch(.failed(.insertionFailed(.axSilentNoop)))
            }

        case .copyToPasteboardAsFallback(let text):
            _ = await MainActor.run { SystemPasteboard().clearAndWrite(text, concealed: false) }

        case .installModel:
            await downloadModel()

        case .scheduleDismiss(let after):
            Task { [weak self] in
                try? await Task.sleep(for: after)
                await self?.dispatch(.dismissRequested)
            }

        case .play(let feedback):
            updateContinuation.yield(.feedback(feedback))

        case .showHUD, .hideHUD:
            break   // UI 側が phase を見て反応する
        }
    }

    // MARK: - 取り込みと認識

    private func startCapture(target: InsertionTarget) async {
        let request = TranscriptionRequest(
            locale: Locale(identifier: settings.transcription.locale),
            termHints: settings.transcription.termHints.compactMap(TermHint.parse),
            wantsPartialResults: settings.transcription.showPartialResults,
            punctuation: settings.transcription.punctuation == "automatic")

        let g = beginGeneration()

        if case .needsModelDownload = await provider.readiness(for: request) {
            await dispatch(.modelProgress(0)); return
        }
        guard isCurrent(g) else {
            Log.session.info("モデル確認中にキャンセルされたため開始しない")
            return
        }

        buffer.reset()
        levelEmitCount = 0
        do {
            let s = try await provider.startSession(request)
            // セッション生成中にキャンセルされていたら、作った分を畳んで降りる。
            guard isCurrent(g) else {
                Log.session.info("セッション開始中にキャンセルされたため破棄する")
                await s.cancel()
                return
            }
            session = s

            // 認識結果は損失不可。actor 内で直接消費する。
            resultTask = Task { [weak self] in
                do {
                    for try await event in s.events {
                        await self?.apply(event: event)
                    }
                } catch {
                    await self?.dispatch(.failed(.transcriptionFailed(.transcriberUnavailable)))
                }
            }

            let format = await provider.preferredFormat(for: request)
            guard isCurrent(g) else {
                Log.session.info("フォーマット取得中にキャンセルされたため録音しない")
                resultTask?.cancel()
                await s.cancel()
                session = nil
                return
            }

            let stream = try await capture.start(format: format) { [weak self] level in
                Task { await self?.emitLevel(level) }
            }
            // **ここが本命。** マイクを開いた直後にキャンセル済みだと分かったら、
            // すぐ閉じる。放置すると録音ランプが点いたまま残る。
            guard isCurrent(g) else {
                Log.session.info("録音開始直後にキャンセルされたため停止する")
                await capture.stop()
                resultTask?.cancel()
                await s.cancel()
                session = nil
                return
            }

            // 音声は損失許容（bufferingNewest）。詰まっても無制限に食わない。
            pumpTask = Task { [weak self] in
                for await chunk in stream {
                    try? await s.append(chunk)
                    if Task.isCancelled { break }
                }
                _ = self
            }
            await dispatch(.audioStarted)
            armMaxDuration(generation: g)
        } catch {
            Log.audio.error("録音を開始できません: \(String(describing: error), privacy: .public)")
            await dispatch(.failed(.audioUnavailable(.microphoneNotGranted)))
        }
    }

    private func apply(event: TranscriptionEvent) {
        let before = buffer.snapshot()
        buffer.apply(event)
        let after = buffer.snapshot()

        // 暫定結果が確定時に訂正されることがある（「今日は」→「公共は」）。
        // 本文は出さず、置き換わった事実と長さだけ残す。
        if case .finalized = event, !before.volatileTail.isEmpty,
           before.volatileTail != after.committed.suffix(before.volatileTail.count) {
            Log.speech.info("暫定を訂正: \(before.volatileTail.count, privacy: .public) 文字 → 確定")
        }
        updateContinuation.yield(.snapshot(after))
    }

    private func emitLevel(_ level: Float) {
        // HUD は 20Hz で十分。描画が追いつかなくても最新だけ映ればよい。
        let now = ContinuousClock.now
        guard now - lastLevelEmit >= .milliseconds(50) else { return }
        lastLevelEmit = now
        levelEmitCount += 1
        // 診断用: 最初の数回だけ実測値を残す。波形が動かないときの切り分けに使う。
        if levelEmitCount <= 3 {
            Log.audio.info("音量: \(level, privacy: .public)")
        }
        updateContinuation.yield(.level(level))
    }

    private func downloadModel() async {
        let locale = Locale(identifier: settings.transcription.locale)
        do {
            try await provider.downloadModel(for: locale) { [weak self] p in
                Task { await self?.emitModelProgress(p) }
            }
            await dispatch(.modelReady)
        } catch {
            await dispatch(.failed(.transcriptionFailed(.modelAssetsMissing(locale.identifier))))
        }
    }

    private func emitModelProgress(_ p: Double) { updateContinuation.yield(.modelProgress(p)) }

    // MARK: - 修飾キーの解放待ち

    /// PTT の ⌃⌥ を押したまま ⌘V を合成すると ⌃⌥⌘V になり、ペーストにならない。
    /// **時間切れでそのまま挿入してはいけない。** 諦めてペーストボードに残すほうがまし。
    private func waitForModifierRelease(text: String) async {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let flags = CGEventSource.flagsState(.hidSystemState)
            let held: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            if flags.intersection(held).isEmpty {
                let waited = ContinuousClock.now - start
                if waited > .milliseconds(100) {
                    Log.session.info("修飾キーの解放を待った: \(waited.components.attoseconds / 1_000_000_000_000_000, privacy: .public)ms")
                }
                await dispatch(.modifiersReleased)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let flags = CGEventSource.flagsState(.hidSystemState)
        Log.session.error("修飾キーが 3 秒解放されない flags=\(String(flags.rawValue, radix: 16), privacy: .public)")
        await dispatch(.modifierWaitTimedOut)
    }
}

/// 校正の結果。**実行したかどうかを含める。**
/// 「変化なし」だけでは呼ばれなかったのか区別できない。
public struct RefineOutcome: Sendable {
    public let text: String
    public let ran: Bool
    public let note: String?
    public init(text: String, ran: Bool, note: String? = nil) {
        self.text = text; self.ran = ran; self.note = note
    }
}
