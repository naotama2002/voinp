import Foundation
import VoinpCore
import VoinpNet

/// OpenAI 互換 API のクライアント。
/// LM Studio / Ollama / llama.cpp server / vLLM / 社内の互換ゲートウェイが対象。
///
/// ネットワークは必ず `EgressGate` を通す。ここに `URLSession` は現れない。
public struct OpenAICompatibleClient: LLMClient, Sendable {
    public let identifier = "openai-compatible"

    private let baseURL: URL
    private let model: String
    private let credential: CredentialRef?
    private let gate: EgressGate

    public init(baseURL: URL, model: String, credential: CredentialRef?, gate: EgressGate) {
        self.baseURL = baseURL
        self.model = model
        self.credential = credential
        self.gate = gate
    }

    public func listModels() async throws -> [ModelInfo] {
        let probe = EndpointProbe(gate: gate)
        switch await probe.discover(rawInput: baseURL.absoluteString) {
        case .success(let d): return d.models
        case .failure(let f): throw f
        }
    }

    public func complete(_ request: CompletionRequest) async throws -> CompletionResult {
        // ストリーミングはしない。出力は一括で挿入されるので、
        // トークンを描画する場所が無く、パーサだけが増える。
        var payload: [String: Any] = [
            "model": request.model.isEmpty ? model : request.model,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
            "stream": false,
        ]
        if let t = request.temperature { payload["temperature"] = t }
        if let m = request.maxOutputTokens { payload["max_tokens"] = m }
        if !request.stop.isEmpty { payload["stop"] = request.stop }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let url = baseURL.appending(path: "chat/completions")

        let started = ContinuousClock.now
        let response = try await gate.send(EgressRequest(
            purpose: .refine, providerID: identifier, url: url, method: "POST",
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            secretRefs: credential.map { ["Authorization": .bearer($0)] } ?? [:],
            body: body, timeout: request.timeout,
            // **書き起こしを含む。** 監査とポリシー判定でこれが効く。
            carriesUserContent: true))

        guard (200..<300).contains(response.status) else {
            throw LLMError.server(status: response.status)
        }
        guard let text = Self.extractContent(response.body) else {
            throw LLMError.unexpectedResponse
        }
        return CompletionResult(text: text, latency: ContinuousClock.now - started)
    }

    /// 応答から本文を取り出す。実装差に寛容にする。
    static func extractContent(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // 標準形: choices[0].message.content
        if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
            if let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
            // 一部の実装は text を返す
            if let text = first["text"] as? String { return text }
        }
        return nil
    }
}

public enum LLMError: Error, Sendable, Equatable {
    case server(status: Int)
    case unexpectedResponse
    case timedOut
}
