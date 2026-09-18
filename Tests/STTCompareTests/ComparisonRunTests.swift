import Foundation
import Testing
import VoinpCore
@testable import STTCompare

/// 台本どおりに動くエンジン。
struct StubProvider: TranscriptionProvider {
    let identifier: String
    let session: StubSession
    let failsToStart: Bool

    init(identifier: String, session: StubSession, failsToStart: Bool = false) {
        self.identifier = identifier
        self.session = session
        self.failsToStart = failsToStart
    }

    func readiness(for request: TranscriptionRequest) async -> Readiness { .ready }
    func downloadModel(for locale: Locale,
                       progress: @Sendable @escaping (Double) -> Void) async throws {}
    func preferredFormat(for request: TranscriptionRequest) async -> AudioFormatDescription {
        AudioFormatDescription(sampleRate: 16_000, channelCount: 1, isInt16: true)
    }
    func startSession(_ request: TranscriptionRequest) async throws -> any TranscriptionSession {
        struct Boom: Error {}
        if failsToStart { throw Boom() }
        return session
    }
}

actor StubSession: TranscriptionSession {
    nonisolated let events: AsyncThrowingStream<TranscriptionEvent, any Error>
    private let continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    private(set) var receivedChunks = 0

    init() {
        let parts = AsyncThrowingStream<TranscriptionEvent, any Error>.makeStream()
        events = parts.stream
        continuation = parts.continuation
    }

    func append(_ chunk: AudioChunk) async throws { receivedChunks += 1 }
    func finish() async throws {}
    func cancel() async { continuation.finish() }

    func emit(_ event: TranscriptionEvent) { continuation.yield(event) }
    func endStream() { continuation.finish() }
}

@Suite("比較の進行")
struct ComparisonRunTests {

    private func engine(_ id: String, _ session: StubSession,
                        failsToStart: Bool = false) -> Engine {
        Engine(id: id, displayName: id,
               format: AudioFormatDescription(sampleRate: 16_000, channelCount: 1,
                                              isInt16: true),
               makeProvider: {
                   StubProvider(identifier: id, session: session, failsToStart: failsToStart)
               })
    }

    private func request() -> TranscriptionRequest {
        TranscriptionRequest(locale: Locale(identifier: "ja-JP"))
    }

    /// **1 つ落ちても比較を続けること。**
    /// 全部止まると何も分からない。落ちたエンジンだけ失敗と出す。
    @Test("接続に失敗したエンジンがあっても他は動く")
    func oneFailureDoesNotStopOthers() async {
        let good = StubSession()
        let run = ComparisonRun(engines: [
            engine("ok", good),
            engine("broken", StubSession(), failsToStart: true),
        ])
        await run.start(request: request())

        let results = await run.snapshot
        #expect(results.first { $0.id == "ok" }?.state == .listening)
        if case .failed = results.first(where: { $0.id == "broken" })?.state {} else {
            Issue.record("失敗したエンジンが .failed になること")
        }
    }

    /// 列の並びが安定していること。**毎回入れ替わると比べられない。**
    @Test("結果の並び順は登録順で固定")
    func orderIsStable() async {
        let run = ComparisonRun(engines: [
            engine("apple", StubSession()),
            engine("openai", StubSession()),
            engine("gemini", StubSession()),
        ])
        await run.start(request: request())
        #expect(await run.snapshot.map(\.id) == ["apple", "openai", "gemini"])
    }

    /// 暫定は置換、確定は追記。voinp の `TranscriptBuffer` と同じ規約。
    @Test("暫定は置き換わり、確定は積み上がる")
    func partialReplacesAndFinalAccumulates() async throws {
        let session = StubSession()
        let run = ComparisonRun(engines: [engine("e", session)])
        await run.start(request: request())

        await session.emit(.partial("今日は"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(await run.snapshot.first?.text == "今日は")

        await session.emit(.partial("今日はいい天気"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(await run.snapshot.first?.text == "今日はいい天気",
                "暫定は置き換わること（追記だと二重になる）")

        await session.emit(.finalized(TranscriptSegment(text: "今日はいい天気です。")))
        try await Task.sleep(for: .milliseconds(40))
        let result = await run.snapshot.first
        #expect(result?.committed == "今日はいい天気です。")
        #expect(result?.volatile == "", "確定したら暫定は消えること")
    }

    /// **レイテンシは共通の基準から測ること。**
    /// エンジンごとに別の基準で測ると比較にならない。
    @Test("最初の文字までの時間を記録する")
    func recordsFirstTextLatency() async throws {
        let session = StubSession()
        let run = ComparisonRun(engines: [engine("e", session)])
        await run.start(request: request())

        try await Task.sleep(for: .milliseconds(60))
        await session.emit(.partial("あ"))
        try await Task.sleep(for: .milliseconds(40))

        let ms = await run.snapshot.first?.firstTextMs
        #expect(ms != nil, "記録されること")
        #expect((ms ?? 0) >= 50, "録音開始からの経過であること。実際は \(ms ?? -1) ms")
    }

    /// 最初の 1 回だけ記録する。後続の結果で上書きしない。
    @Test("初出の時刻は最初の 1 回だけ")
    func firstTextIsRecordedOnce() async throws {
        let session = StubSession()
        let run = ComparisonRun(engines: [engine("e", session)])
        await run.start(request: request())

        await session.emit(.partial("あ"))
        try await Task.sleep(for: .milliseconds(30))
        let first = await run.snapshot.first?.firstTextMs

        try await Task.sleep(for: .milliseconds(60))
        await session.emit(.partial("あい"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await run.snapshot.first?.firstTextMs == first, "上書きしないこと")
    }

    /// 空の結果では時刻を記録しない。**出ていないのに速いことにしない。**
    @Test("空の暫定では初出を記録しない")
    func emptyTextDoesNotCount() async throws {
        let session = StubSession()
        let run = ComparisonRun(engines: [engine("e", session)])
        await run.start(request: request())

        await session.emit(.partial(""))
        try await Task.sleep(for: .milliseconds(40))
        #expect(await run.snapshot.first?.firstTextMs == nil)
    }
}

/// 設定に書かれた接続先を WebSocket の URL にする部分。
///
/// **本体の設定は `https` のことも `wss` のこともある。**
/// 比較ツールのために書き直させない。
@Suite("接続先の URL の組み立て")
struct RealtimeURLTests {

    @Test("https を wss に変え、realtime とクエリを足す")
    func fromHTTPSBase() {
        let url = realtimeURL(from: "https://x.openai.azure.com/openai/v1")
        #expect(url?.absoluteString
                == "wss://x.openai.azure.com/openai/v1/realtime?intent=transcription")
    }

    /// 既に整った URL を壊さない。本体でクラウドを設定済みならこの形。
    @Test("既に wss と realtime を含む URL はそのまま")
    func alreadyComplete() {
        let complete = "wss://x.openai.azure.com/openai/v1/realtime?intent=transcription"
        #expect(realtimeURL(from: complete)?.absoluteString == complete)
    }

    /// **`?intent=transcription` は Azure でも必須。**
    /// 付けない URL は 101 が返らない（実測）。
    @Test("realtime だけあってクエリが無ければ足す")
    func addsIntentQuery() {
        let url = realtimeURL(from: "wss://x.openai.azure.com/openai/v1/realtime")
        #expect(url?.absoluteString.contains("intent=transcription") == true)
    }

    @Test("末尾のスラッシュを落とす")
    func trimsTrailingSlash() {
        let url = realtimeURL(from: "https://x.openai.azure.com/openai/v1/")
        #expect(url?.absoluteString.contains("/v1/realtime") == true)
        #expect(url?.absoluteString.contains("//realtime") == false)
    }

    @Test("空なら nil")
    func emptyIsNil() {
        #expect(realtimeURL(from: "") == nil)
        #expect(realtimeURL(from: "   ") == nil)
    }

    /// **実機の設定で踏んだ形。** クエリが先に付いている URL に
    /// 素朴に `/realtime` を足すと、クエリの後ろに付いて壊れる:
    ///   `.../v1?intent=transcription/realtime`
    @Test("クエリが先に付いていても壊さない")
    func handlesQueryBeforePath() {
        let url = realtimeURL(from:
            "wss://x.openai.azure.com/openai/v1?intent=transcription")
        #expect(url?.path == "/openai/v1/realtime", "パスに /realtime が入ること")
        #expect(url?.query == "intent=transcription", "クエリが 1 つだけ残ること")
    }

    /// intent を二重に付けない。
    @Test("intent を重複させない")
    func doesNotDuplicateIntent() {
        let url = realtimeURL(from:
            "wss://x.openai.azure.com/openai/v1/realtime?intent=transcription")
        #expect(url?.query == "intent=transcription")
    }

    /// 他のクエリがあっても残す。
    @Test("他のクエリを落とさない")
    func keepsOtherQueryItems() {
        let url = realtimeURL(from: "wss://x.openai.azure.com/openai/v1?api-version=2026-05-01")
        #expect(url?.query?.contains("api-version=2026-05-01") == true)
        #expect(url?.query?.contains("intent=transcription") == true)
        #expect(url?.path == "/openai/v1/realtime")
    }
}
