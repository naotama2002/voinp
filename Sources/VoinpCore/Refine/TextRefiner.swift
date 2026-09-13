import Foundation

/// 校正の制御層。
///
/// **`throws` にしない。** ユーザーが喋ったのに何も挿入されない経路を、
/// 型の上で書けなくする。失敗すれば生原稿が返る。
public struct TextRefiner: Sendable {

    public struct Outcome: Sendable, Equatable {
        public let text: String
        public let usedRefinement: Bool
        public let reason: String?
    }

    public struct Policy: Sendable {
        public var hardDeadline: Duration = .seconds(4)
        public var disableAfterConsecutiveFailures = 3
        public var temperature: Double = 0.1
        public var maxOutputTokens = 1024
        public init() {}
    }

    private let client: any LLMClient
    private let model: String
    private let policy: Policy
    private let builder = PromptBuilder()
    private let outputGuard = RefinementGuard()
    private let failures: FailureCounter

    public init(client: any LLMClient, model: String, policy: Policy = Policy(),
                failures: FailureCounter = FailureCounter()) {
        self.client = client
        self.model = model
        self.policy = policy
        self.failures = failures
    }

    public func refine(_ transcript: String, preset: Preset) async -> Outcome {
        guard !preset.skipsLLM else {
            return Outcome(text: transcript, usedRefinement: false, reason: nil)
        }
        guard !transcript.isEmpty else {
            return Outcome(text: transcript, usedRefinement: false, reason: nil)
        }
        // 連続して失敗しているなら試さない。
        // LM Studio を閉じた人が毎回 4 秒待たされるのを防ぐ。
        if await failures.isTripped(limit: policy.disableAfterConsecutiveFailures) {
            return Outcome(text: transcript, usedRefinement: false,
                           reason: "連続失敗のため一時停止中")
        }

        let assembly = builder.assemble(transcript: transcript, preset: preset)
        do {
            let result = try await withThrowingTaskGroup(of: CompletionResult.self) { group in
                group.addTask {
                    try await client.complete(CompletionRequest(
                        model: model, system: assembly.system, user: assembly.user,
                        temperature: preset.temperature, maxOutputTokens: policy.maxOutputTokens,
                        stop: assembly.stopSequences, timeout: policy.hardDeadline))
                }
                group.addTask {
                    try await Task.sleep(for: policy.hardDeadline)
                    throw LLMTimeout()
                }
                guard let first = try await group.next() else { throw LLMTimeout() }
                group.cancelAll()
                return first
            }

            switch outputGuard.evaluate(raw: transcript, candidate: result.text,
                                        policy: preset.guardPolicy, nonce: assembly.nonce) {
            case .accept(let text):
                await failures.reset()
                return Outcome(text: text, usedRefinement: true, reason: nil)
            case .reject(let reason):
                // 棄却は失敗ではない（LLM は応答している）。生原稿に戻すだけ。
                await failures.reset()
                Log.refine.notice("校正を棄却: \(String(describing: reason), privacy: .public)")
                return Outcome(text: transcript, usedRefinement: false,
                               reason: "LLM の出力を棄却（\(Self.describe(reason))）")
            }
        } catch {
            await failures.record()
            Log.refine.error("校正に失敗: \(String(describing: error), privacy: .public)")
            return Outcome(text: transcript, usedRefinement: false,
                           reason: "LLM の呼び出しに失敗")
        }
    }
}

extension TextRefiner {
    /// 棄却理由を短い日本語にする。HUD に出す。
    static func describe(_ r: RefinementGuard.Rejection) -> String {
        switch r {
        case .empty: "空の応答"
        case .lengthRatio(let v): String(format: "長さが %.1f 倍", v)
        case .scriptShift: "言語が変わった"
        case .unrequestedMarkdown: "箇条書きにされた"
        case .answeredQuestion: "質問に答えてしまった"
        case .contentDrift: "内容が変わりすぎ"
        case .numberMismatch(let n): "数値が消えた（\(n.joined(separator: ", "))）"
        case .refusal: "応答を拒否された"
        }
    }
}

struct LLMTimeout: Error {}

/// 連続失敗を数える。3 回続いたら一時停止する。
public actor FailureCounter {
    private var count = 0
    public init() {}
    func record() { count += 1 }
    func reset() { count = 0 }
    func isTripped(limit: Int) -> Bool { count >= limit }
    /// ユーザーが設定を直したときに手動で戻す。
    public func clear() { count = 0 }
}
