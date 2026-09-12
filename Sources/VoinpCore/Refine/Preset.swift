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

    /// 組み込みプリセット。`prompts/<id>.md` があれば上書きされる。
    public static let builtins: [Preset] = [
        Preset(id: "raw", name: "整形なし", order: 0, body: "", skipsLLM: true),
        Preset(id: "clean", name: "そのまま整形", order: 10, body: ""),
        Preset(id: "polite", name: "丁寧語に", order: 20, body: """
            書き起こしを丁寧語（です・ます調）に統一してください。
            敬語の誤用は修正しますが、過度にへりくだった表現にはしないでください。
            内容・情報量は変えないでください。
            """,
            guardPolicy: GuardPolicy(lengthRatio: 0.7...1.8)),
        Preset(id: "slack", name: "Slack 向けに短く", order: 30, body: """
            チャットに投稿する前提で整形してください。
            冗長な前置きは削ってよく、箇条書きにしたほうが読みやすければそうしてください。
            ただし事実・数値・固有名詞・依頼内容は必ず残すこと。
            """,
            guardPolicy: GuardPolicy(lengthRatio: 0.4...1.2, allowMarkdown: true)),
        Preset(id: "translate-en", name: "英訳", order: 40, body: """
            書き起こしを自然な英語に翻訳してください。
            出力は英語のみ。原文の丁寧さのレベルを保ち、訳注は加えないでください。
            """,
            guardPolicy: GuardPolicy(lengthRatio: 0.3...3.0, requireSameScript: false,
                                     enforceQuestionShape: false, contentRetention: nil)),
    ]

    public static func builtin(id: String) -> Preset {
        builtins.first { $0.id == id } ?? builtins[1]   // 既定は clean
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
