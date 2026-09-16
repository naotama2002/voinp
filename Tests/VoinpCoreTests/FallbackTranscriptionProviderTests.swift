import Foundation
import Testing
@testable import VoinpCore

/// 台本どおりに振る舞うプロバイダ。
actor ScriptedProvider: TranscriptionProvider {
    nonisolated let identifier: String
    private let readinessValue: Readiness
    private let startFails: Bool
    private(set) var sessions: [ScriptedSession] = []
    private(set) var downloadCalls = 0

    init(identifier: String, readiness: Readiness = .ready, startFails: Bool = false) {
        self.identifier = identifier
        self.readinessValue = readiness
        self.startFails = startFails
    }

    func readiness(for request: TranscriptionRequest) async -> Readiness { readinessValue }

    func downloadModel(for locale: Locale,
                       progress: @Sendable @escaping (Double) -> Void) async throws {
        downloadCalls += 1
        progress(1.0)
    }

    func preferredFormat(for request: TranscriptionRequest) async -> AudioFormatDescription {
        AudioFormatDescription(sampleRate: identifier == "cloud" ? 24_000 : 16_000,
                               channelCount: 1, isInt16: true)
    }

    func startSession(_ request: TranscriptionRequest) async throws -> any TranscriptionSession {
        struct Boom: Error {}
        if startFails { throw Boom() }
        let session = ScriptedSession()
        sessions.append(session)
        return session
    }

    var latest: ScriptedSession? { sessions.last }
}

actor ScriptedSession: TranscriptionSession {
    nonisolated let events: AsyncThrowingStream<TranscriptionEvent, any Error>
    private let continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    private(set) var received: [AudioChunk] = []
    private(set) var cancelled = false

    init() {
        let parts = AsyncThrowingStream<TranscriptionEvent, any Error>.makeStream()
        events = parts.stream
        continuation = parts.continuation
    }

    func append(_ chunk: AudioChunk) async throws { received.append(chunk) }
    func finish() async throws {}
    func cancel() async { cancelled = true; continuation.finish() }

    /// 台本を進める。
    func emit(_ event: TranscriptionEvent) { continuation.yield(event) }
    func endStream() { continuation.finish() }
    var receivedCount: Int { received.count }
}

@Suite("クラウドからローカルへの退避")
struct FallbackTranscriptionProviderTests {

    private func chunk(_ byte: UInt8) -> AudioChunk {
        AudioChunk(format: AudioFormatDescription(sampleRate: 24_000, channelCount: 1,
                                                  isInt16: true),
                   samples: Data([byte, 0]))
    }

    /// イベントを集める。**必ず期限で打ち切る。**
    ///
    /// 期限を入れないと、実装を壊したときにテストが落ちずに**ハングする**
    /// （`events` が終わらないので `value` が永久に待つ）。
    /// 回帰検査としては「落ちる」ことが要るので、時間で終わらせる。
    private func collect(_ session: any TranscriptionSession,
                         within deadline: Duration = .seconds(2))
        -> Task<[TranscriptionEvent], Never> {
        let box = EventBox()
        let reader = Task {
            do { for try await e in session.events { await box.append(e) } } catch {
                await box.recordFailure("\(error)")
            }
            await box.markFinished()
        }
        return Task {
            let start = ContinuousClock.now
            while ContinuousClock.now - start < deadline, await !box.finished {
                try? await Task.sleep(for: .milliseconds(20))
            }
            reader.cancel()
            if await !box.finished {
                Issue.record("events が期限内に終わらなかった（実装がハングしている）")
            }
            if let failure = await box.failure {
                Issue.record("events がエラーで終わった: \(failure)")
            }
            return await box.events
        }
    }

    /// 終了を検査せずに消費するだけ。
    /// ストリームの終わり方が検査対象でないテストで使う
    /// （`collect` は「期限内に終わること」まで見るので、
    ///  終わらせない台本で使うと偽の失敗になる）。
    private func drain(_ session: any TranscriptionSession) -> Task<Void, Never> {
        Task { _ = try? await session.events.reduce(into: 0) { count, _ in count += 1 } }
    }

    private func summary() -> TranscriptionSummary {
        TranscriptionSummary(fullText: "", locale: Locale(identifier: "ja-JP"),
                             audioDuration: .seconds(1), providerID: "cloud")
    }

    // MARK: - 退避する場合

    /// **本命。** 確定が出ないまま一次が終わったら、保持した音声を二次へ流し直す。
    @Test("確定前に一次が終わったら二次へ音声を流し直す")
    func replaysToSecondaryWhenPrimaryFailsEarly() async throws {
        let cloud = ScriptedProvider(identifier: "cloud")
        let local = ScriptedProvider(identifier: "local")
        let degraded = DegradeFlag()
        let provider = FallbackTranscriptionProvider(
            primary: cloud, secondary: local, onDegrade: { degraded.set() })

        let session = try await provider.startSession(TranscriptionRequest(
            locale: Locale(identifier: "ja-JP")))
        let consumer = drain(session)
        defer { consumer.cancel() }

        for i in 0..<5 { try await session.append(chunk(UInt8(i))) }
        try await Task.sleep(for: .milliseconds(50))

        // 一次が確定を出さずに終わる
        await cloud.latest?.endStream()
        try await Task.sleep(for: .milliseconds(120))

        let replayed = await local.latest?.receivedCount
        #expect(replayed == 5, "保持していた 5 チャンクが二次へ流れること")
        #expect(degraded.value, "退避したことを呼び出し側へ伝えること")
    }

    /// **確定後は差し替えない。** リプレイすると同じ発話が二重に入る。
    @Test("確定が出た後に切れても差し替えない")
    func doesNotSwapAfterCommit() async throws {
        let cloud = ScriptedProvider(identifier: "cloud")
        let local = ScriptedProvider(identifier: "local")
        let provider = FallbackTranscriptionProvider(primary: cloud, secondary: local)

        let session = try await provider.startSession(TranscriptionRequest(
            locale: Locale(identifier: "ja-JP")))
        let events = collect(session)

        try await session.append(chunk(1))
        try await Task.sleep(for: .milliseconds(50))
        await cloud.latest?.emit(.finalized(TranscriptSegment(text: "確定した")))
        try await Task.sleep(for: .milliseconds(50))
        await cloud.latest?.endStream()
        try await Task.sleep(for: .milliseconds(120))

        let sessions = await local.sessions.count
        #expect(sessions == 0, "二次を起こさないこと")
        let out = await events.value
        #expect(out.contains(.finalized(TranscriptSegment(text: "確定した"))))
    }

    /// 退避先も駄目なときに**エラーで終わらせない**。
    /// events をエラーで終えると SessionMachine が abortEverything に落ち、
    /// それまでの認識結果を全部捨てる。
    @Test("退避先も起動できなくてもエラーで終わらせない")
    func secondaryFailureStillEndsCleanly() async throws {
        let cloud = ScriptedProvider(identifier: "cloud")
        let local = ScriptedProvider(identifier: "local", startFails: true)
        let provider = FallbackTranscriptionProvider(primary: cloud, secondary: local)

        let session = try await provider.startSession(TranscriptionRequest(
            locale: Locale(identifier: "ja-JP")))
        let events = collect(session)

        await cloud.latest?.endStream()
        _ = await events.value   // 返ってくれば正常終了している
    }

    /// 差し替えを待つ間、一次の `.ended` を先に流してはいけない。
    /// 流すと `SessionMachine` が先へ進み、退避先の結果が挿入に間に合わない。
    @Test("確定前の一次の ended は握りつぶす")
    func swallowsPrimaryEndedBeforeCommit() async throws {
        let cloud = ScriptedProvider(identifier: "cloud")
        let local = ScriptedProvider(identifier: "local")
        let provider = FallbackTranscriptionProvider(primary: cloud, secondary: local)

        let session = try await provider.startSession(TranscriptionRequest(
            locale: Locale(identifier: "ja-JP")))
        let events = collect(session)

        await cloud.latest?.emit(.ended(summary()))
        await cloud.latest?.endStream()
        try await Task.sleep(for: .milliseconds(120))

        // 二次が確定を出して初めて終わる
        await local.latest?.emit(.finalized(TranscriptSegment(text: "退避先の結果")))
        await local.latest?.emit(.ended(summary()))
        try await Task.sleep(for: .milliseconds(80))

        let out = await events.value
        #expect(out.contains(.finalized(TranscriptSegment(text: "退避先の結果"))))
        #expect(out.filter { if case .ended = $0 { true } else { false } }.count == 1,
                "ended は 1 回だけ")
    }

    // MARK: - 最初から二次を使う場合

    @Test("一次が使えないなら最初から二次で始める")
    func startsOnSecondaryWhenPrimaryNotReady() async throws {
        let cloud = ScriptedProvider(identifier: "cloud",
                                     readiness: .unsupported("鍵が未設定"))
        let local = ScriptedProvider(identifier: "local")
        let provider = FallbackTranscriptionProvider(primary: cloud, secondary: local)

        _ = try await provider.startSession(TranscriptionRequest(
            locale: Locale(identifier: "ja-JP")))
        #expect(await local.sessions.count == 1)
        #expect(await cloud.sessions.isEmpty)
    }

    // MARK: - 準備状態と資産

    /// **一次が使えても二次の資産は要る。** 退避先にモデルが無ければ、
    /// 落ちたときに何も残らない。
    @Test("二次のモデルが無ければ取得を促す")
    func requiresSecondaryAssets() async throws {
        let cloud = ScriptedProvider(identifier: "cloud")
        let local = ScriptedProvider(
            identifier: "local",
            readiness: .needsModelDownload(Locale(identifier: "ja-JP")))
        let provider = FallbackTranscriptionProvider(primary: cloud, secondary: local)

        let readiness = await provider.readiness(for: TranscriptionRequest(
            locale: Locale(identifier: "ja-JP")))
        #expect(readiness == .needsModelDownload(Locale(identifier: "ja-JP")))
    }

    @Test("モデル取得は二次へ委譲する")
    func downloadDelegatesToSecondary() async throws {
        let cloud = ScriptedProvider(identifier: "cloud")
        let local = ScriptedProvider(identifier: "local")
        let provider = FallbackTranscriptionProvider(primary: cloud, secondary: local)

        try await provider.downloadModel(for: Locale(identifier: "ja-JP")) { _ in }
        #expect(await local.downloadCalls == 1)
        #expect(await cloud.downloadCalls == 0, "クラウドに取得すべき資産は無い")
    }

    /// 取り込みは一次のフォーマットで行う。退避時のレート差は二次側が吸収する。
    @Test("取り込みフォーマットは一次に合わせる")
    func usesPrimaryFormat() async throws {
        let provider = FallbackTranscriptionProvider(
            primary: ScriptedProvider(identifier: "cloud"),
            secondary: ScriptedProvider(identifier: "local"))
        let format = await provider.preferredFormat(for: TranscriptionRequest(
            locale: Locale(identifier: "ja-JP")))
        #expect(format.sampleRate == 24_000)
    }
}

/// 退避が呼ばれたかを並行文脈から記録する。
final class DegradeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// 収集結果を並行文脈から安全に持つ。
actor EventBox {
    private(set) var events: [TranscriptionEvent] = []
    private(set) var finished = false
    private(set) var failure: String?

    func append(_ e: TranscriptionEvent) { events.append(e) }
    func markFinished() { finished = true }
    func recordFailure(_ message: String) { failure = message }
}
