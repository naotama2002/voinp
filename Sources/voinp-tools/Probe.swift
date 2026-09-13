import Foundation
import VoinpCore
import VoinpNet
import VoinpProviders

/// LLM エンドポイントの疎通確認。`make probe-llm URL=... KEY=...`
enum ProbeTool {
    static func run(urlString: String, apiKey: String?) async {
        // 検証用に、この URL だけを許可するポリシーを組む。
        let host = URL(string: urlString)?.host
            ?? urlString.replacingOccurrences(of: "https://", with: "")
        let snapshot = EgressPolicySnapshot(
            masterAllow: true, maxClass: .publicInternet,
            allowedHosts: [host],
            allowedPurposes: [.modelDiscovery, .refine], probeCandidate: nil)

        let store = InMemoryCredentials(value: apiKey)
        let gate = EgressGate(policy: { snapshot }, credentials: store)
        let ref = apiKey != nil ? CredentialRef(account: "probe") : nil

        print("接続先: \(urlString)")
        print("到達範囲: \(await (try? HostClassifier().classify(host: host)).map { "\($0)" } ?? "判定不可")")

        let probe = EndpointProbe(gate: gate)
        switch await probe.discover(rawInput: urlString) {
        case .success(let d):
            print("✅ 接続成功")
            print("   正規化 URL: \(d.normalizedBaseURL.absoluteString)")
            print("   モデル \(d.models.count) 件:")
            for m in d.models.prefix(20) { print("     - \(m.id)") }
            if d.models.count > 20 { print("     … 他 \(d.models.count - 20) 件") }
        case .failure(let f):
            print("❌ \(f.message)")
            print("   詳細: \(f)")
            return
        }

        // 実際に校正してみる
        guard let model = try? await OpenAICompatibleClient(
            baseURL: URL(string: urlString + "/v1")!, model: "", credential: ref, gate: gate
        ).listModels().first else { return }

        let client = OpenAICompatibleClient(
            baseURL: URL(string: urlString + "/v1")!, model: model.id,
            credential: ref, gate: gate)

        let sample = ProcessInfo.processInfo.environment["VOINP_SAMPLE"]
            ?? "えーと、今日はサイボウズの東京本社に出張に行って、その後すみだ水族館に行きました。あのー、Kintoneのゴルフボールがあってそれを購入しちゃいましたよ"
        print("\n--- 校正テスト ---")
        print("入力: \(sample)")

        let builder = PromptBuilder()
        let userPrompt = ProcessInfo.processInfo.environment["VOINP_PROMPT"] ?? ""
        let preset = Preset.fromUserPrompt(userPrompt)
        if !userPrompt.isEmpty { print("プロンプト: \(userPrompt)") }
        let assembly = builder.assemble(transcript: sample, preset: preset)
        do {
            let started = ContinuousClock.now
            let result = try await client.complete(CompletionRequest(
                model: model.id, system: assembly.system, user: assembly.user,
                temperature: 0.1, maxOutputTokens: 1024,
                stop: assembly.stopSequences, timeout: .seconds(60)))
            let elapsed = ContinuousClock.now - started
            print("出力: \(result.text)")
            print("所要: \(elapsed.components.seconds) 秒")

            let verdict = RefinementGuard().evaluate(
                raw: sample, candidate: result.text,
                policy: preset.guardPolicy, nonce: assembly.nonce)
            switch verdict {
            case .accept(let t): print("ガード: 通過\n最終: \(t)")
            case .reject(let r): print("ガード: 棄却 (\(r)) → 生原稿を挿入する")
            }
        } catch {
            print("❌ 校正失敗: \(error)")
        }
    }
}

struct InMemoryCredentials: CredentialStore {
    let value: String?
    func read(_ ref: CredentialRef) throws -> String? { value }
    func write(_ value: String, to ref: CredentialRef) throws {}
    func delete(_ ref: CredentialRef) throws {}
}
