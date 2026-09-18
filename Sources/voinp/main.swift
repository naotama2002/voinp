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

// **クライアントは呼ばれるたびに作る。**
// 起動時に作って抱えると、設定で接続先を変えても古い URL のまま呼び続ける。
let makeClient: @Sendable (Settings) -> (any LLMClient)? = { settings in
    let c = settings.refinement.openaiCompatible
    guard settings.refinement.provider == "openai-compatible",
          let url = URL(string: c.baseURL) else { return nil }
    // **資格情報は接続先ホストにひも付ける。**
    // 共通の口座名を渡していた頃は、接続先を変えると前のサーバー用の
    // API キーがそのまま新しいサーバーへ送られていた。
    return OpenAICompatibleClient(
        baseURL: url, model: c.model,
        credential: c.requiresAPIKey ? CredentialRef.openAICompatible(host: url.host) : nil,
        gate: gate)
}

// モデル探索は closure で渡す。UI 層がネットワークの型を知らずに済む。
// 資格情報は `EndpointProbe` が正規化後のホストから自分で引くので、ここでは渡さない。
let discover: @Sendable (String) async -> ModelDiscoveryResult = { input in
    switch await EndpointProbe(gate: gate).discover(rawInput: input) {
    case .success(let d):
        return .success(baseURL: d.normalizedBaseURL.absoluteString, models: d.models)
    case .failure(let f):
        return .failure(f.message)
    }
}

VoinpRoot.run(Dependencies(makeLLMClient: makeClient,
                           settings: loaded.settings,
                           configError: loaded.error,
                           credentials: credentials,
                           discoverModels: discover))
