import Foundation
import VoinpCore
import VoinpNet
import VoinpProviders
import VoinpUIKit

// 通常版: ネットワークを使う校正プロバイダを登録する。
let settings = Settings()
var clients: [any LLMClient] = []
if let url = URL(string: settings.refinement.openaiCompatible.baseURL) {
    clients.append(OpenAICompatibleClient(baseURL: url, model: settings.refinement.openaiCompatible.model))
}
VoinpRoot.run(Dependencies.base().withLLM(clients))
