import Foundation
import VoinpCore
import VoinpNet

/// OpenAI 互換 API (LM Studio / Ollama /v1 / llama.cpp server / vLLM) のクライアント。
/// ネットワークアクセスは必ず `EgressGate` を通す。ここに `URLSession` は現れない。
public struct OpenAICompatibleClient: LLMClient {
    public let identifier = "openai-compatible"

    private let baseURL: URL
    private let model: String

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    public func listModels() async throws -> [ModelInfo] {
        // TODO: EndpointProbe 経由で GET {base}/models。docs/03-refinement.md 参照。
        throw VoinpError.egressDenied(.networkDisabled)
    }

    public func complete(_ request: CompletionRequest) async throws -> CompletionResult {
        // TODO: POST {base}/chat/completions。docs/03-refinement.md 参照。
        throw VoinpError.egressDenied(.networkDisabled)
    }
}
