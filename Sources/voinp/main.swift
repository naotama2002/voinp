import Foundation
import VoinpCore
import VoinpEngine
import VoinpNet
import VoinpProviders
import VoinpUIKit

// 通常版の合成ルート。**ネットワークを知るのはここだけ。**
let loaded = ConfigStore().load()
if let e = loaded.error { FileHandle.standardError.write(Data("設定エラー: \(e)\n".utf8)) }

let credentials = KeychainStore()

// 送信ポリシーは設定から導出する。設定が壊れていれば全拒否。
let gate = EgressGate(
    policy: { @Sendable in
        let current = ConfigStore().load()
        return EgressPolicySnapshot.derive(from: current.settings,
                                           hasConfigError: current.hasError)
    },
    credentials: credentials)

var clients: [any LLMClient] = []
let refinement = loaded.settings.refinement
if refinement.provider == "openai-compatible",
   let url = URL(string: refinement.openaiCompatible.baseURL) {
    clients.append(OpenAICompatibleClient(
        baseURL: url,
        model: refinement.openaiCompatible.model,
        credential: refinement.openaiCompatible.requiresAPIKey
            ? CredentialRef(account: "openai-compatible/apiKey") : nil,
        gate: gate))
}

// モデル探索は closure で渡す。UI 層がネットワークの型を知らずに済む。
let discover: @Sendable (String) async -> ModelDiscoveryResult = { input in
    let probe = EndpointProbe(gate: gate)
    let ref = CredentialRef(account: "openai-compatible/apiKey")
    switch await probe.discover(rawInput: input, credential: ref) {
    case .success(let d): return .success(d.models)
    case .failure(let f): return .failure(f.message)
    }
}

VoinpRoot.run(Dependencies(llmClients: clients,
                           settings: loaded.settings,
                           configError: loaded.error,
                           credentials: credentials,
                           discoverModels: discover))
