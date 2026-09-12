import Foundation
import VoinpCore
import VoinpEngine
import VoinpNet
import VoinpProviders
import VoinpUIKit

// 通常版の合成ルート。ネットワークを知るのはここだけ。
let loaded = ConfigStore().load()
if let e = loaded.error { FileHandle.standardError.write(Data("設定エラー: \(e)\n".utf8)) }

var clients: [any LLMClient] = []
if loaded.settings.refinement.enabled,
   loaded.settings.refinement.provider == "openai-compatible",
   let url = URL(string: loaded.settings.refinement.openaiCompatible.baseURL) {
    clients.append(OpenAICompatibleClient(
        baseURL: url, model: loaded.settings.refinement.openaiCompatible.model))
}

VoinpRoot.run(Dependencies(llmClients: clients,
                           settings: loaded.settings,
                           configError: loaded.error))
