import Foundation
import Testing
import VoinpCore
@testable import VoinpEngine

/// 開始処理の途中でキャンセルされたときの振る舞い。
///
/// レビュー指摘 4「キャンセル後も、開始処理が再開できます」に対応する。
/// `startCapture` はモデル準備・セッション開始・フォーマット取得と何度も await する。
/// actor はその中断点で他のメッセージを受けるので、待っている間に HUD から
/// キャンセルされうる。以前はそこから戻ったあと素通しで録音を開始しており、
/// **状態機械が idle に戻ったあとでマイクが開く**経路があった。
@Suite("開始中のキャンセル")
struct CancellationRaceTests {

    // MARK: - 差し替え用のプロバイダ

    /// `startSession` を任意のタイミングまで待たせられるプロバイダ。
    /// 実機のタイミングに頼らず、競合を決定的に再現する。
    actor GatedProvider: TranscriptionProvider {
        nonisolated let identifier = "gated"

        private var release: CheckedContinuation<Void, Never>?
        private var entered: CheckedContinuation<Void, Never>?
        private(set) var startedSessions = 0
        private(set) var cancelledSessions = 0
        /// 実際に渡されたリクエスト。**組み立て直さず、通った値を見る。**
        private(set) var lastRequest: TranscriptionRequest?

        nonisolated func readiness(for request: TranscriptionRequest) async -> Readiness {
            .ready
        }

        nonisolated func downloadModel(
            for locale: Locale, progress: @Sendable @escaping (Double) -> Void) async throws {}

        nonisolated func preferredFormat(
            for request: TranscriptionRequest) async -> AudioFormatDescription {
            AudioFormatDescription(sampleRate: 16000, channelCount: 1, isInt16: true)
        }

        func startSession(_ request: TranscriptionRequest) async throws -> any TranscriptionSession {
            lastRequest = request
            startedSessions += 1
            // 呼ばれたことを外へ知らせ、外から解放されるまで中断する。
            entered?.resume()
            entered = nil
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                release = c
            }
            return GatedSession(owner: self)
        }

        /// `startSession` に入るまで待つ。
        func waitUntilEntered() async {
            guard startedSessions == 0 else { return }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                entered = c
            }
        }

        /// 中断している `startSession` を進ませる。
        func releaseStart() {
            release?.resume()
            release = nil
        }

        func noteCancelled() { cancelledSessions += 1 }
    }

    actor GatedSession: TranscriptionSession {
        private let owner: GatedProvider
        private let parts = AsyncThrowingStream<TranscriptionEvent, any Error>.makeStream()
        nonisolated let events: AsyncThrowingStream<TranscriptionEvent, any Error>

        init(owner: GatedProvider) {
            self.owner = owner
            self.events = parts.stream
        }

        func append(_ chunk: AudioChunk) async throws {}
        func finish() async throws { parts.continuation.finish() }
        func cancel() async {
            await owner.noteCancelled()
            parts.continuation.finish()
        }
    }

    // MARK: - 検査

    /// **本題。** セッション生成の最中にキャンセルすると、
    /// 戻ってきた `startCapture` は自分が失効したと判断して降りる。
    /// 作りかけのセッションは畳む（放置すると認識エンジンが動いたまま残る）。
    @Test("セッション生成中にキャンセルすると録音を開始せず、作った分を畳む")
    func cancelDuringStartSession() async throws {
        let provider = GatedProvider()
        let coordinator = DictationCoordinator(
            settings: Settings(),
            provider: provider,
            inserter: NoopInserter())

        // 開始要求 → startSession の中で止まる
        let starting = Task { await coordinator.handle(command: .start) }
        await provider.waitUntilEntered()

        // 止まっている間にキャンセルする
        await coordinator.handle(command: .cancel)

        // 開始処理を再開させる
        await provider.releaseStart()
        await starting.value

        // 少しだけ余韻を与えて、後片付けまで走らせる
        try await Task.sleep(for: .milliseconds(50))

        let cancelled = await provider.cancelledSessions
        #expect(cancelled == 1, "作りかけのセッションを畳むこと")

        let phase = await coordinator.phaseForTesting
        #expect(phase == .idle, "キャンセル後に idle 以外へ進まないこと")
    }

    /// 設定が**実際にプロバイダへ渡る値**として届くこと。
    /// 既存の伝播テストはリクエストを組み立て直して検査しており、
    /// 組み立て箇所の不具合を見逃す構造だった（レビューの指摘どおり）。
    @Test("認識の設定は本番経路を通ってプロバイダへ届く")
    func settingsReachProviderThroughRealPath() async throws {
        let provider = GatedProvider()
        var settings = Settings()
        settings.transcription.locale = "en-US"
        settings.transcription.termHints = ["kintone", "サイボウズ"]
        settings.transcription.punctuation = "automatic"

        let coordinator = DictationCoordinator(
            settings: settings, provider: provider, inserter: NoopInserter())

        let starting = Task { await coordinator.handle(command: .start) }
        await provider.waitUntilEntered()
        await coordinator.handle(command: .cancel)
        await provider.releaseStart()
        await starting.value

        let request = await provider.lastRequest
        #expect(request?.locale.identifier == "en-US")
        #expect(request?.termHints.count == 2)
        #expect(request?.punctuation == true)
    }
}

/// 何もしない挿入。挿入経路はここでは検査しない。
actor NoopInserter: TextInserter {
    nonisolated let identifier = "noop"
    func insert(_ text: String, into target: InsertionTarget) async throws {}
}
