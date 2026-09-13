import Foundation

/// 校正プリセット。`prompts/*.md` に対応する。
public struct Preset: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let order: Int
    /// L2 の本文。空なら L0+L1 だけで動く。
    public let body: String
    /// L1 を丸ごと置き換える場合（`prompts/base.md`）。
    public let baseOverride: String?
    /// LLM を呼ばずそのまま挿入する。
    public let skipsLLM: Bool
    public let guardPolicy: GuardPolicy
    public let temperature: Double

    public init(id: String, name: String, order: Int = 0, body: String,
                baseOverride: String? = nil, skipsLLM: Bool = false,
                guardPolicy: GuardPolicy = GuardPolicy(), temperature: Double = 0.1) {
        self.id = id; self.name = name; self.order = order; self.body = body
        self.baseOverride = baseOverride; self.skipsLLM = skipsLLM
        self.guardPolicy = guardPolicy; self.temperature = temperature
    }

    /// 設定に書かれた指示から組み立てる。
    ///
    /// **プリセットは持たない。** 用意した分類（丁寧語 / Slack 向け / 英訳…）は
    /// 使う人の用途に合わず、選ばせること自体が手間だった。
    /// ユーザーが自分の言葉で書いたものをそのまま渡す。
    public static func fromUserPrompt(_ prompt: String) -> Preset {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return Preset(id: "user", name: "校正", order: 0, body: trimmed,
                      guardPolicy: policy(for: trimmed))
    }

    /// 書かれた指示から、出力ガードの厳しさを推定する。
    ///
    /// 「英訳して」と書いた人の出力を、文字種チェックで棄却しては意味がない。
    /// 指示の内容に応じて必要な検査だけを緩める。
    static func policy(for prompt: String) -> GuardPolicy {
        var p = GuardPolicy()
        let lower = prompt.lowercased()

        let translating = ["英訳", "translate", "英語に", "in english"]
            .contains { lower.contains($0.lowercased()) }
        if translating {
            p.requireSameScript = false
            p.enforceQuestionShape = false
            p.contentRetention = nil
            p.lengthRatio = 0.3...3.0
        }

        let shortening = ["短く", "簡潔", "要約", "まとめ"].contains { prompt.contains($0) }
        if shortening { p.lengthRatio = 0.3...p.lengthRatio.upperBound }

        let listing = ["箇条書き", "リスト", "markdown", "マークダウン"]
            .contains { lower.contains($0.lowercased()) }
        if listing { p.allowMarkdown = true }

        return p
    }
}

/// 出力ガードの厳しさ。プリセットごとに変わる。
public struct GuardPolicy: Sendable, Equatable {
    public var lengthRatio: ClosedRange<Double> = 0.5...2.0
    /// 短い入力では比率が無意味なので、文字数の差で見る。
    public var absoluteSlackForShortInput: Int = 15
    public var requireSameScript: Bool = true
    public var allowMarkdown: Bool = false
    public var enforceNumbers: Bool = true
    public var enforceQuestionShape: Bool = true
    /// 固有名詞などがどれだけ残っているか。
    ///
    /// **0.7 は厳しすぎた。** 校正の主目的が同音異義語の修正
    /// （「公園会」→「講演会」）である以上、漢字トークンが変わるのは正常であり、
    /// 短い文ではそれだけで 0.67 まで落ちて棄却されてしまった。
    /// 0.5 にして、半分以上が保たれていれば通す。
    /// 完全な作り替え（要約・別の話題）は長さ比と文字種の検査で捕まる。
    public var contentRetention: Double? = 0.5

    public init(lengthRatio: ClosedRange<Double> = 0.5...2.0,
                absoluteSlackForShortInput: Int = 15,
                requireSameScript: Bool = true,
                allowMarkdown: Bool = false,
                enforceNumbers: Bool = true,
                enforceQuestionShape: Bool = true,
                contentRetention: Double? = 0.5) {
        self.lengthRatio = lengthRatio
        self.absoluteSlackForShortInput = absoluteSlackForShortInput
        self.requireSameScript = requireSameScript
        self.allowMarkdown = allowMarkdown
        self.enforceNumbers = enforceNumbers
        self.enforceQuestionShape = enforceQuestionShape
        self.contentRetention = contentRetention
    }
}
