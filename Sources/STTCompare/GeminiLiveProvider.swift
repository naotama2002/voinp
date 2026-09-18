import Foundation
import VoinpCore
import VoinpEngine
import VoinpNet
import VoinpProviders

/// Gemini Live による音声認識。
///
/// OpenAI 系と同じ `TranscriptionProvider` に載せるので、比較ツールからは
/// macOS のエンジンと区別なく扱える。ただし**ワイヤプロトコルは別物**で、
/// 特に暫定結果の意味が逆（あちらは追記、こちらは全文）。
public struct GeminiLiveProvider: TranscriptionProvider {
    public let identifier = "gemini.live"

    private let config: GeminiLiveConfig
    private let endpoint: URL
    private let injection: SecretInjection?
    private let gate: EgressGate

    /// - Parameter injection: API キーの参照。
    ///   **URL のクエリに載せない。** ドキュメントは `?key=` を示しているが、
    ///   載せると「秘密はゲートの中で初めて値になる」性質が崩れ、
    ///   呼び出し側が鍵を String で持つことになる。ヘッダで渡す。
    public init(config: GeminiLiveConfig, endpoint: URL,
                injection: SecretInjection?, gate: EgressGate) {
        self.config = config
        self.endpoint = endpoint
        self.injection = injection
        self.gate = gate
    }

    public func readiness(for request: TranscriptionRequest) async -> Readiness {
        guard endpoint.scheme?.lowercased() == "wss" else {
            return .unsupported("接続先が wss の URL ではありません")
        }
        guard !config.model.isEmpty else { return .unsupported("モデルが未設定です") }
        return .ready
    }

    public func downloadModel(for locale: Locale,
                              progress: @Sendable @escaping (Double) -> Void) async throws {
        progress(1.0)   // クラウドに取得すべき資産は無い。投げない。
    }

    public func preferredFormat(for request: TranscriptionRequest) async -> AudioFormatDescription {
        AudioFormatDescription(sampleRate: Double(GeminiLiveConfig.sampleRate),
                               channelCount: 1, isInt16: true)
    }

    public func startSession(_ request: TranscriptionRequest) async throws
        -> any TranscriptionSession {
        var sessionConfig = config
        sessionConfig.customVocabulary = request.termHints.map(\.text)

        let egress = EgressRequest(
            purpose: .transcribe, providerID: identifier, url: endpoint,
            secretRefs: injection.map { ["x-goog-api-key": $0] } ?? [:],
            timeout: .seconds(10), carriesUserContent: true)
        let gate = self.gate

        let session = GeminiLiveSession(config: sessionConfig) {
            try await gate.connect(egress)
        }
        // 接続を待たずに返す。待つとその間マイクが開かず発話の頭が消える。
        await session.beginConnecting()
        return session
    }
}

/// Gemini Live の 1 セッション。
///
/// voinp の `RealtimeTranscriptionSession` と同じ規約を守る:
/// - **`events` をエラーで終わらせない**（呼び出し側が結果を全部捨ててしまう）
/// - `append()` で待たない
/// - 接続を待たずに返し、届いた音声は preroll に積む
public actor GeminiLiveSession: TranscriptionSession {

    public nonisolated let events: AsyncThrowingStream<TranscriptionEvent, any Error>
    private let continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation

    private let config: GeminiLiveConfig
    private let connect: @Sendable () async throws -> any EgressWebSocketChannel

    private var channel: (any EgressWebSocketChannel)?
    private var packetizer = PCM16FramePacketizer()
    private var preroll = PrerollBuffer()
    private var ready = false
    private var ended = false
    private var committed = ""
    private var lifecycle: Task<Void, Never>?
    private var sendQueue: AsyncStream<Data>.Continuation?
    private var sendTask: Task<Void, Never>?

    public init(config: GeminiLiveConfig,
                connect: @escaping @Sendable () async throws -> any EgressWebSocketChannel) {
        self.config = config
        self.connect = connect
        let parts = AsyncThrowingStream<TranscriptionEvent, any Error>.makeStream()
        self.events = parts.stream
        self.continuation = parts.continuation
    }

    public func beginConnecting() {
        guard lifecycle == nil else { return }
        lifecycle = Task { [weak self] in await self?.run() }
    }

    public func append(_ chunk: AudioChunk) async throws {
        guard !ended else { return }
        for frame in packetizer.append(chunk.samples) {
            if ready { sendQueue?.yield(GeminiLiveConfig.audioPayload(frame)) }
            else { preroll.append(frame) }
        }
    }

    public func finish() async throws {
        guard !ended, let channel else { return await close() }
        if let tail = packetizer.flushWithSilencePadding() {
            if ready { sendQueue?.yield(GeminiLiveConfig.audioPayload(tail)) }
            else { preroll.append(tail) }
        }
        sendQueue?.finish()
        await sendTask?.value
        try? await channel.send(GeminiLiveConfig.audioStreamEnd)

        // 確定が出そろうのを少し待つ。来なければ持っている分で終える。
        try? await Task.sleep(for: .seconds(2))
        await close()
    }

    public func cancel() async {
        guard !ended else { return }
        ended = true
        lifecycle?.cancel()
        sendQueue?.finish()
        sendTask?.cancel()
        await channel?.close()
        channel = nil
        continuation.finish()
    }

    // MARK: - 接続

    private func run() async {
        let channel: any EgressWebSocketChannel
        do { channel = try await connect() } catch { return await close() }
        guard !ended else { return await channel.close() }
        self.channel = channel

        let (stream, queue) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(100))
        sendQueue = queue
        sendTask = Task { for await payload in stream { try? await channel.send(payload) } }

        do { try await channel.send(config.setupPayload()) } catch { return await close() }

        while !ended {
            let data: Data
            do { data = try await channel.receive() } catch { return await close() }

            switch GeminiLiveWireEvent.decode(data) {
            case .setupComplete:
                ready = true
                for frame in preroll.drain() {
                    sendQueue?.yield(GeminiLiveConfig.audioPayload(frame))
                }

            case .interimTranscript(let text):
                // **そのまま置換。** Gemini の暫定は全文なので累積しない。
                continuation.yield(.partial(text))

            case .finalTranscript(let text):
                committed += text
                continuation.yield(.finalized(TranscriptSegment(text: text)))
                continuation.yield(.partial(""))

            case .error:
                return await close()

            case .turnComplete, .ignored:
                break
            }
        }
    }

    /// 唯一の終了経路。**エラーで終わらせない。**
    private func close() async {
        guard !ended else { return }
        ended = true
        continuation.yield(.ended(TranscriptionSummary(
            fullText: committed, locale: Locale(identifier: "ja-JP"),
            audioDuration: .zero, providerID: "gemini.live")))
        continuation.finish()
        sendQueue?.finish()
        sendTask?.cancel()
        lifecycle?.cancel()
        await channel?.close()
        channel = nil
    }
}
