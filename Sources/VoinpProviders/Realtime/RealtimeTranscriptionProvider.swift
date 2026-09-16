import Foundation
import VoinpCore
import VoinpNet

/// OpenAI Realtime 互換のクラウド音声認識。
///
/// **`readiness` で通信しない。** ここは `DictationCoordinator.startCapture` の
/// 先頭から毎回呼ばれる＝ホットキーを押すたびに走る。往復を入れると、
/// 会社の外にいるときに押すたびタイムアウトを待つことになる。
/// 監査ログに「ユーザーが何もしていないのに出た通信」が溜まるのも避けたい。
/// 疎通確認は設定画面の接続テストで行う。
public struct RealtimeTranscriptionProvider: TranscriptionProvider {
    public let identifier = CloudTranscriptionProviderID.openAIRealtime

    private let config: RealtimeSessionConfig
    private let endpoint: URL
    private let authHeader: String
    private let injection: SecretInjection?
    private let handshakeTimeout: Duration
    private let gate: EgressGate

    public init(config: RealtimeSessionConfig, endpoint: URL,
                authHeader: String, injection: SecretInjection?,
                handshakeTimeout: Duration, gate: EgressGate) {
        self.config = config
        self.endpoint = endpoint
        self.authHeader = authHeader
        self.injection = injection
        self.handshakeTimeout = handshakeTimeout
        self.gate = gate
    }

    public func readiness(for request: TranscriptionRequest) async -> Readiness {
        guard endpoint.scheme?.lowercased() == "wss" || endpoint.scheme?.lowercased() == "ws"
        else { return .unsupported("接続先が WebSocket の URL ではありません") }
        guard !config.model.isEmpty else { return .unsupported("モデル（デプロイ名）が未設定です") }
        return .ready
    }

    /// クラウドに取得すべき資産は無い。**投げない。**
    /// 到達しない経路だが、到達したときに黙って通るほうが安全
    /// （投げると `SessionMachine` が HUD をエラーで止める）。
    public func downloadModel(for locale: Locale,
                              progress: @Sendable @escaping (Double) -> Void) async throws {
        progress(1.0)
    }

    /// **24kHz 固定。** 16000 はサーバーが拒否する（実測）。
    public func preferredFormat(for request: TranscriptionRequest) async -> AudioFormatDescription {
        AudioFormatDescription(sampleRate: Double(RealtimeSessionConfig.sampleRate),
                               channelCount: 1, isInt16: true)
    }

    public func startSession(_ request: TranscriptionRequest) async throws
        -> any TranscriptionSession {
        // 用語ヒントをそのまま認識バイアスへ渡す。
        var sessionConfig = config
        sessionConfig.keywords = request.termHints.map(\.text)

        let egress = EgressRequest(
            purpose: .transcribe, providerID: identifier, url: endpoint,
            secretRefs: injection.map { [authHeader: $0] } ?? [:],
            timeout: handshakeTimeout, carriesUserContent: true)
        let gate = self.gate

        let session = RealtimeTranscriptionSession(
            config: sessionConfig, handshakeTimeout: handshakeTimeout,
            connect: { try await gate.connect(egress) })
        // **接続を待たずに返す。** 待つとその間マイクが開かず、発話の頭が消える。
        await session.beginConnecting()
        return session
    }
}
