import Foundation
import VoinpCore
import VoinpNet

/// クラウド認識の 1 セッション。
///
/// ## 守らなければならないこと
///
/// **1. `events` をエラーで終わらせない。**
/// `DictationCoordinator.resultTask` は `catch` で `.failed` を dispatch し、
/// `SessionMachine` が `abortEverything` に落ちて**それまでの認識結果を全部捨てる**。
/// どんな失敗でも「溜まった分を `.finalized` にして `.ended` を出し、正常終了」に変換する。
///
/// **2. `append()` で待たない。**
/// `DictationCoordinator.pumpTask` は `for await chunk in stream { await s.append(chunk) }` と
/// 直列に回っている。ここで送信を待つと `AudioCapture` の `bufferingNewest(256)` が溢れ、
/// **発話が中抜けする**。パケット化してキューに積むだけにする。
///
/// **3. 接続を待たない。**
/// `startSession()` が返るまでマイクは開かない。ハンドシェイクは実測 1,089ms なので、
/// そこで待つと発話の頭が物理的に消える。接続中の音声は `PrerollBuffer` へ積み、
/// `session.updated` を受けた瞬間に順番に吐き出す。
public actor RealtimeTranscriptionSession: TranscriptionSession {

    public nonisolated let events: AsyncThrowingStream<TranscriptionEvent, any Error>
    private let eventContinuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation

    private let config: RealtimeSessionConfig
    private let connect: @Sendable () async throws -> any EgressWebSocketChannel
    private let handshakeTimeout: Duration
    private let finishTimeout: Duration

    private var channel: (any EgressWebSocketChannel)?
    private var packetizer = PCM16FramePacketizer()
    private var preroll = PrerollBuffer()
    private var assembler = RealtimeTranscriptAssembler()

    private var ready = false
    private var ended = false
    private var sentFrames = 0
    private var didComplete = false
    private var lifecycle: Task<Void, Never>?
    private var sendQueue: AsyncStream<Data>.Continuation?
    private var sendTask: Task<Void, Never>?

    /// 失敗の理由。`.ended` を出す前に呼び出し側へ伝えるための帯域外の通知。
    /// `TranscriptionEvent` に case を足すと `SessionMachine` の網羅 switch が壊れるので、
    /// Core の列挙体には触らない。
    public private(set) var failure: RealtimeFailure?

    public init(config: RealtimeSessionConfig,
                handshakeTimeout: Duration = .seconds(5),
                finishTimeout: Duration = .seconds(3),
                connect: @escaping @Sendable () async throws -> any EgressWebSocketChannel) {
        self.config = config
        self.connect = connect
        self.handshakeTimeout = handshakeTimeout
        self.finishTimeout = finishTimeout
        let parts = AsyncThrowingStream<TranscriptionEvent, any Error>.makeStream()
        self.events = parts.stream
        self.eventContinuation = parts.continuation
    }

    /// 接続を始める。**待たずに返る。**
    public func beginConnecting() {
        guard lifecycle == nil else { return }
        lifecycle = Task { [weak self] in await self?.runLifecycle() }
    }

    // MARK: - TranscriptionSession

    public func append(_ chunk: AudioChunk) async throws {
        guard !ended else { return }
        for frame in packetizer.append(chunk.samples) { enqueue(frame) }
    }

    public func finish() async throws {
        guard !ended else { return }
        // 端数を捨てない。発話の末尾が消える。
        if let tail = packetizer.flushWithSilencePadding() { enqueue(tail) }

        // まだ繋がっていないなら、送るものが無いので待たずに畳む。
        guard ready, let channel else { return await close(reason: nil) }

        sendQueue?.finish()
        await sendTask?.value
        try? await channel.send(RealtimeSessionConfig.commit)

        // 確定を待つ。来なければ溜まった分を自分で確定させる。
        let deadline = ContinuousClock.now + finishTimeout
        while ContinuousClock.now < deadline, !didComplete {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await close(reason: didComplete ? nil : .noFinalTranscript)
    }

    public func cancel() async {
        guard !ended else { return }
        ended = true
        lifecycle?.cancel()
        sendQueue?.finish()
        sendTask?.cancel()
        await channel?.close()
        channel = nil
        eventContinuation.finish()
    }

    // MARK: - 接続とハンドシェイク

    private func runLifecycle() async {
        let channel: any EgressWebSocketChannel
        do {
            channel = try await connect()
        } catch {
            return await close(reason: .connectFailed(describe(error)))
        }
        guard !ended else { return await channel.close() }
        self.channel = channel
        startSendLoop(on: channel)

        // ハンドシェイクを時間で打ち切る。receive() は Task キャンセルを見ないので、
        // 期限が来たら close() して待ちを解くしかない。
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: self?.handshakeTimeout ?? .seconds(5))
            await self?.failHandshake()
        }

        do {
            try await handshake(on: channel)
        } catch {
            watchdog.cancel()
            return await close(reason: .handshakeFailed(describe(error)))
        }
        watchdog.cancel()
        guard !ended else { return }

        ready = true
        for frame in preroll.drain() { enqueue(frame) }

        await receiveLoop(on: channel)
    }

    private func handshake(on channel: any EgressWebSocketChannel) async throws {
        // 接続直後に session.created が来る。それを待ってから設定を送る。
        while true {
            let event = RealtimeWireEvent.decode(try await channel.receive())
            if case .sessionCreated = event { break }
            if case .serverError(let e) = event { throw RealtimeHandshakeError(e.message) }
        }
        try await channel.send(config.payload())
        while true {
            let event = RealtimeWireEvent.decode(try await channel.receive())
            if case .sessionUpdated = event { return }
            if case .serverError(let e) = event { throw RealtimeHandshakeError(e.message) }
        }
    }

    private func failHandshake() async {
        guard !ready, !ended else { return }
        await channel?.close()   // receive() の待ちを解く
    }

    // MARK: - 受信

    private func receiveLoop(on channel: any EgressWebSocketChannel) async {
        while !ended {
            let data: Data
            do {
                data = try await channel.receive()
            } catch {
                // 切断。**エラーで終わらせず**、取れている分を確定して正常終了する。
                return await close(reason: .disconnected)
            }
            let wire = RealtimeWireEvent.decode(data)
            if case .serverError(let e) = wire, e.isFatal {
                return await close(reason: .serverError(e.message))
            }
            if case .transcriptCompleted = wire { didComplete = true }
            for event in assembler.ingest(wire) { eventContinuation.yield(event) }
        }
    }

    // MARK: - 送信

    private func startSendLoop(on channel: any EgressWebSocketChannel) {
        // 10 秒分まで溜める。溢れたら**古いほうから捨てる**。
        // ここで待つと取り込み側が詰まるので、捨てるほうを選ぶ。
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(100))
        sendQueue = continuation
        sendTask = Task {
            for await frame in stream {
                try? await channel.send(RealtimeSessionConfig.appendAudio(frame))
            }
        }
    }

    /// 接続前なら preroll へ、接続後はキューへ。**どちらも待たない。**
    private func enqueue(_ frame: Data) {
        if ready {
            sendQueue?.yield(frame)
            sentFrames += 1
        } else {
            preroll.append(frame)
        }
    }

    // MARK: - 終了

    /// **唯一の終了経路。** 何度呼ばれても 1 度しか効かない。
    /// どの失敗からもここへ集約し、`.ended` を出して**正常終了**する。
    private func close(reason: RealtimeFailure?) async {
        guard !ended else { return }
        ended = true
        failure = reason

        for event in assembler.finish() { eventContinuation.yield(event) }
        eventContinuation.yield(.ended(TranscriptionSummary(
            fullText: "",
            locale: Locale(identifier: config.languages.first ?? "ja"),
            audioDuration: .milliseconds(sentFrames * PCM16FramePacketizer.frameDurationMilliseconds),
            providerID: "openai.realtime")))
        eventContinuation.finish()

        sendQueue?.finish()
        sendTask?.cancel()
        lifecycle?.cancel()
        await channel?.close()
        channel = nil
    }

    private func describe(_ error: any Error) -> String {
        if let e = error as? RealtimeHandshakeError { return e.message }
        return (error as NSError).localizedDescription
    }
}

/// 退避の判断材料。**本文は含めない。**
public enum RealtimeFailure: Sendable, Equatable {
    case connectFailed(String)
    case handshakeFailed(String)
    case disconnected
    case serverError(String)
    /// commit したのに確定が返ってこなかった。溜まった分は拾ってある。
    case noFinalTranscript

    /// 再接続して直る見込みがあるか。
    /// 認証やポリシーの失敗は何度やっても同じなので、すぐ退避する。
    public var isRetryable: Bool {
        switch self {
        case .disconnected, .noFinalTranscript: true
        case .connectFailed, .handshakeFailed, .serverError: false
        }
    }
}

struct RealtimeHandshakeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
