import CoreGraphics
import Foundation
import VoinpCore

/// セッションの唯一の真実。`SessionMachine` を所有し、各ポートを駆動する。
/// UI にはスロットルした snapshot だけを流す（@Published を 70 個持つ ViewModel を避ける）。
public actor DictationCoordinator {

    public enum Update: Sendable {
        case phase(SessionPhase)
        case snapshot(TranscriptSnapshot)
        case level(Float)
        case modelProgress(Double)
        case feedback(Feedback)
    }

    public nonisolated let updates: AsyncStream<Update>
    private nonisolated let updateContinuation: AsyncStream<Update>.Continuation

    private var machine = SessionMachine()
    private var buffer = TranscriptBuffer()
    private var settings: Settings

    private let provider: any TranscriptionProvider
    /// 設定で切り替わるので固定しない。
    private var inserter: any TextInserter
    private let capture = AudioCapture()
    private let refine: @Sendable (String) async -> String

    private var session: (any TranscriptionSession)?
    private var pumpTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var lastLevelEmit = ContinuousClock.now
    private var levelEmitCount = 0

    public init(settings: Settings,
                provider: any TranscriptionProvider,
                inserter: any TextInserter,
                refine: @escaping @Sendable (String) async -> String = { $0 }) {
        self.settings = settings
        self.provider = provider
        self.inserter = inserter
        self.refine = refine
        // 音量は 20Hz で流れるので、phase や snapshot と同じ流れに乗せると
        // bufferingNewest で捨てられやすい。多めに確保する。
        let parts = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.updates = parts.stream
        self.updateContinuation = parts.continuation
    }

    public func update(settings: Settings) {
        let strategyChanged = settings.insertion != self.settings.insertion
        self.settings = settings
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

    public func handle(command: SessionCommand) async {
        switch command {
        case .start:
            let target = await MainActor.run { InsertionTargetResolver.current() }
            await dispatch(.startRequested(target: target))
        case .stop:
            await dispatch(.stopRequested)
        case .cancel:
            await dispatch(.cancelRequested)
        }
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

    private func perform(_ action: SessionAction) async {
        switch action {
        case .startCapture(let target):
            await startCapture(target: target)

        case .stopCaptureAndFinalize:
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
            await dispatch(.transcriptionFinished(text: text))

        case .abortEverything:
            await capture.stop()
            pumpTask?.cancel()
            resultTask?.cancel()
            await session?.cancel()
            session = nil

        case .refine(let text):
            guard settings.refinement.enabled else {
                await dispatch(.refinementFinished(text: text)); return
            }
            // 校正は失敗しても生原稿が返る。ここで分岐は要らない。
            let result = await refine(text)
            if result != text {
                Log.refine.info("校正あり: \(text.count, privacy: .public) → \(result.count, privacy: .public) 文字")
            }
            await dispatch(.refinementFinished(text: result))

        case .waitForModifierRelease(let text):
            await waitForModifierRelease(text: text)

        case .insert(let text, let target):
            do {
                try await inserter.insert(text, into: target)
                await dispatch(.insertionFinished(.inserted(strategy: inserter.identifier)))
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
            termHints: settings.transcription.termHints.map(TermHint.init),
            wantsPartialResults: settings.transcription.showPartialResults,
            punctuation: settings.transcription.punctuation == "automatic")

        if case .needsModelDownload = await provider.readiness(for: request) {
            await dispatch(.modelProgress(0)); return
        }

        buffer.reset()
        levelEmitCount = 0
        do {
            let s = try await provider.startSession(request)
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
            let stream = try await capture.start(format: format) { [weak self] level in
                Task { await self?.emitLevel(level) }
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
        } catch {
            Log.audio.error("録音を開始できません: \(String(describing: error), privacy: .public)")
            await dispatch(.failed(.audioUnavailable(.microphoneNotGranted)))
        }
    }

    private func apply(event: TranscriptionEvent) {
        buffer.apply(event)
        updateContinuation.yield(.snapshot(buffer.snapshot()))
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
