import Foundation
import Testing
import VoinpCore
import VoinpNet
@testable import VoinpProviders

/// 台本どおりに応答する WebSocket のフェイク。
///
/// 実ネットワークなしでライフサイクル全体を駆動する。
/// `close()` で `receive()` の待ちが解けることまで再現してある
/// （本物の `URLSessionWebSocketTask.receive()` は Task キャンセルを見ないので、
///   時間で打ち切るには close() するしかない。そこを模す）。
actor FakeChannel: EgressWebSocketChannel {
    private var inbox: [Data]
    private(set) var sent: [[String: Any]] = []
    private var closed = false
    private var waiter: CheckedContinuation<Data, any Error>?
    /// receive() を止めたまま返さないモード（ハンドシェイク超過の再現）
    private let stalls: Bool

    init(script: [[String: Any]] = [], stalls: Bool = false) {
        self.inbox = script.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        self.stalls = stalls
    }

    nonisolated var bytes: (out: Int, in: Int) { (0, 0) }

    func push(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            inbox.append(data)
        }
    }

    func send(_ json: Data) async throws {
        if let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
            sent.append(object)
        }
    }

    func receive() async throws -> Data {
        if closed { throw CancellationError() }
        if !stalls, !inbox.isEmpty { return inbox.removeFirst() }
        return try await withCheckedThrowingContinuation { c in
            if closed { c.resume(throwing: CancellationError()) } else { waiter = c }
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    var sentTypes: [String] { sent.compactMap { $0["type"] as? String } }
}

@Suite("Realtime セッションのライフサイクル")
struct RealtimeSessionTests {

    private func config() -> RealtimeSessionConfig {
        RealtimeSessionConfig(model: "gpt-live-transcribe", keywords: ["kintone"])
    }

    private func collect(
        _ session: RealtimeTranscriptionSession) -> Task<[TranscriptionEvent], Never> {
        Task {
            var out: [TranscriptionEvent] = []
            // **エラーで終わってはいけない。** 終わったらここで拾えず落ちる。
            do {
                for try await e in session.events { out.append(e) }
            } catch {
                Issue.record("events がエラーで終わった: \(error)")
            }
            return out
        }
    }

    // MARK: - 正常系

    @Test("ハンドシェイクを終えてから音声を送る")
    func handshakeThenAudio() async throws {
        let channel = FakeChannel(script: [
            ["type": "session.created"],
            ["type": "session.updated"],
        ])
        let session = RealtimeTranscriptionSession(config: config()) { channel }
        let events = collect(session)
        await session.beginConnecting()

        // ready になるまで少し待つ
        try await Task.sleep(for: .milliseconds(120))
        try await session.append(AudioChunk(
            format: AudioFormatDescription(sampleRate: 24_000, channelCount: 1, isInt16: true),
            samples: Data(count: PCM16FramePacketizer.bytesPerFrame)))

        await channel.push([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "i1", "transcript": "こんにちは",
        ])
        try await Task.sleep(for: .milliseconds(80))
        try await session.finish()

        let types = await channel.sentTypes
        #expect(types.first == "session.update", "設定を最初に送ること")
        #expect(types.contains("input_audio_buffer.append"))
        #expect(types.last == "input_audio_buffer.commit")

        let out = await events.value
        #expect(out.contains(.finalized(TranscriptSegment(text: "こんにちは"))))
        #expect(out.last.map { if case .ended = $0 { true } else { false } } == true)
    }

    /// **一番効く検査。** ハンドシェイク中の音声を 1 フレームも落とさないこと。
    /// 実測でハンドシェイクは 1,089ms かかる。ここを落とすと発話の頭が消える。
    @Test("接続前に届いた音声も接続後に全部送る")
    func prerollIsNotLost() async throws {
        let channel = FakeChannel()      // まだ何も返さない
        let session = RealtimeTranscriptionSession(config: config()) { channel }
        _ = collect(session)
        await session.beginConnecting()

        let format = AudioFormatDescription(sampleRate: 24_000, channelCount: 1, isInt16: true)
        for _ in 0..<5 {
            try await session.append(AudioChunk(
                format: format, samples: Data(count: PCM16FramePacketizer.bytesPerFrame)))
        }
        // この時点では 1 フレームも送られていない
        #expect(await channel.sentTypes.filter { $0 == "input_audio_buffer.append" }.isEmpty)

        await channel.push(["type": "session.created"])
        try await Task.sleep(for: .milliseconds(50))
        await channel.push(["type": "session.updated"])
        try await Task.sleep(for: .milliseconds(150))

        let appends = await channel.sentTypes.filter { $0 == "input_audio_buffer.append" }
        #expect(appends.count == 5, "溜めた 5 フレームが全部送られること")
    }

    @Test("停止時に端数を無音で埋めて送る")
    func flushesRemainder() async throws {
        let channel = FakeChannel(script: [
            ["type": "session.created"], ["type": "session.updated"],
        ])
        let session = RealtimeTranscriptionSession(config: config()) { channel }
        _ = collect(session)
        await session.beginConnecting()
        try await Task.sleep(for: .milliseconds(120))

        // 1 フレームに満たない量
        try await session.append(AudioChunk(
            format: AudioFormatDescription(sampleRate: 24_000, channelCount: 1, isInt16: true),
            samples: Data(count: 1_000)))
        try await session.finish()

        let appends = await channel.sentTypes.filter { $0 == "input_audio_buffer.append" }
        #expect(appends.count == 1, "端数も 1 フレームとして送ること")
    }

    // MARK: - 失敗系。**どれも events をエラーで終わらせない**

    @Test("接続に失敗しても events は正常終了する")
    func connectFailureEndsCleanly() async throws {
        struct Boom: Error {}
        let session = RealtimeTranscriptionSession(config: config()) { throw Boom() }
        let events = collect(session)
        await session.beginConnecting()

        let out = await events.value
        #expect(out.last.map { if case .ended = $0 { true } else { false } } == true)
        let failure = await session.failure
        #expect(failure?.isRetryable == false, "接続失敗は再試行しても直らない")
    }

    @Test("ハンドシェイクが返らないと時間で打ち切る")
    func handshakeTimeout() async throws {
        let channel = FakeChannel(stalls: true)
        let session = RealtimeTranscriptionSession(
            config: config(), handshakeTimeout: .milliseconds(100)) { channel }
        let events = collect(session)
        await session.beginConnecting()

        let out = await events.value
        #expect(out.last.map { if case .ended = $0 { true } else { false } } == true)
        if case .handshakeFailed = await session.failure {} else {
            Issue.record("ハンドシェイク失敗として記録されること")
        }
    }

    /// **切断で発話を捨てない。** 溜まっている暫定分を確定として拾う。
    @Test("途中で切れても取れている分を確定させる")
    func disconnectKeepsPartial() async throws {
        let channel = FakeChannel(script: [
            ["type": "session.created"], ["type": "session.updated"],
        ])
        let session = RealtimeTranscriptionSession(config: config()) { channel }
        let events = collect(session)
        await session.beginConnecting()
        try await Task.sleep(for: .milliseconds(120))

        await channel.push([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "i1", "delta": "途中まで",
        ])
        try await Task.sleep(for: .milliseconds(60))
        await channel.close()          // 切断

        let out = await events.value
        #expect(out.contains(.finalized(TranscriptSegment(text: "途中まで"))),
                "取れている分を捨てないこと")
        #expect(out.last.map { if case .ended = $0 { true } else { false } } == true)
    }

    @Test("サーバーの致命エラーでも正常終了する")
    func fatalServerErrorEndsCleanly() async throws {
        let channel = FakeChannel(script: [
            ["type": "session.created"], ["type": "session.updated"],
        ])
        let session = RealtimeTranscriptionSession(config: config()) { channel }
        let events = collect(session)
        await session.beginConnecting()
        try await Task.sleep(for: .milliseconds(120))

        await channel.push(["type": "error",
                            "error": ["message": "quota exceeded", "code": "insufficient_quota"]])

        let out = await events.value
        #expect(out.last.map { if case .ended = $0 { true } else { false } } == true)
        if case .serverError = await session.failure {} else {
            Issue.record("サーバーエラーとして記録されること")
        }
    }

    @Test("cancel でストリームが閉じる")
    func cancelClosesStream() async throws {
        let channel = FakeChannel(stalls: true)
        let session = RealtimeTranscriptionSession(config: config()) { channel }
        let events = collect(session)
        await session.beginConnecting()
        await session.cancel()
        _ = await events.value   // 返ってくれば閉じている
    }
}

@Suite("session.update の組み立て")
struct RealtimeSessionConfigTests {

    private func decode(_ c: RealtimeSessionConfig) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: c.payload())) as? [String: Any] ?? [:]
    }

    private func input(_ c: RealtimeSessionConfig) -> [String: Any] {
        let session = decode(c)["session"] as? [String: Any] ?? [:]
        let audio = session["audio"] as? [String: Any] ?? [:]
        return audio["input"] as? [String: Any] ?? [:]
    }

    @Test("rate は 24000 固定")
    func rateIs24k() {
        let format = input(RealtimeSessionConfig(model: "m"))["format"] as? [String: Any]
        #expect(format?["rate"] as? Int == 24_000,
                "16000 はサーバーに拒否される（実測）")
    }

    /// `noise_reduction` は `transcription` の中ではなく `audio.input` 直下。
    /// 位置を間違えると設定全体が拒否される。
    @Test("noise_reduction は audio.input 直下に置く")
    func noiseReductionPlacement() {
        let i = input(RealtimeSessionConfig(model: "m"))
        #expect(i["noise_reduction"] != nil)
        let t = i["transcription"] as? [String: Any]
        #expect(t?["noise_reduction"] == nil, "transcription の中ではない")
    }

    /// `<` `>` が入ると `session.update` 全体が拒否される（参考実装の知見）。
    @Test("山括弧を含む keywords は落とす")
    func dropsAngleBrackets() {
        let c = RealtimeSessionConfig(model: "m", keywords: ["kintone", "<script>", "Garoon"])
        let t = input(c)["transcription"] as? [String: Any]
        #expect(t?["keywords"] as? [String] == ["kintone", "Garoon"])
    }

    @Test("keywords は 64 語、prompt は 1000 文字で切る")
    func limits() {
        let c = RealtimeSessionConfig(model: "m",
                                      keywords: (0..<100).map { "k\($0)" },
                                      prompt: String(repeating: "あ", count: 2_000))
        let t = input(c)["transcription"] as? [String: Any]
        #expect((t?["keywords"] as? [String])?.count == 64)
        #expect((t?["prompt"] as? String)?.count == 1_000)
    }

    /// VAD をサーバーに任せない。voinp はホットキーで区切るので、
    /// 勝手にターンを切られると確定のタイミングが読めなくなる。
    @Test("turn_detection は null")
    func turnDetectionIsNull() {
        #expect(input(RealtimeSessionConfig(model: "m"))["turn_detection"] is NSNull)
    }

    @Test("言語ヒントを複数渡せる")
    func languages() {
        let t = input(RealtimeSessionConfig(model: "m", languages: ["ja", "en"]))["transcription"]
            as? [String: Any]
        #expect(t?["languages"] as? [String] == ["ja", "en"])
    }
}
