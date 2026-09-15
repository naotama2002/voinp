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

// クラウド音声認識。**設定から毎回組み立てる。**
// 実体を抱えると接続先やモデルを変えても古いまま使い続ける。
// オフライン版はこの closure を渡さないので、クラウドは存在しない。
let makeCloudSTT: @Sendable (Settings) -> (any TranscriptionProvider)? = { settings in
    // 旗印の唯一の分岐点。5 条件が揃っていなければ nil。
    guard settings.cloudTranscriptionDestination != nil else { return nil }
    let c = settings.transcription.realtime
    guard let url = URL(string: c.endpointURL), let host = url.host else { return nil }

    let injection: SecretInjection? = c.requiresAPIKey
        ? CredentialRef.openAIRealtime(host: host).map {
            c.authScheme == "raw" ? .raw($0) : .bearer($0)
        }
        : nil

    return RealtimeTranscriptionProvider(
        config: RealtimeSessionConfig(
            model: c.model, languages: c.languages, keywords: [],
            prompt: "", delay: c.delay, noiseReduction: c.noiseReduction),
        endpoint: url, authHeader: c.authHeader, injection: injection,
        handshakeTimeout: .milliseconds(c.handshakeTimeoutMs), gate: gate)
}

VoinpRoot.run(Dependencies(makeLLMClient: makeClient,
                           settings: loaded.settings,
                           configError: loaded.error,
                           credentials: credentials,
                           discoverModels: discover,
                           makeCloudSpeechProvider: makeCloudSTT))
