import Foundation

/// LLM の出力が信用できるかを判定する。
///
/// プロンプトは緩和であって保証ではない。
/// **出力側の検査が独立した第 2 層**で、インジェクションが成功した場合も
/// たいてい長さ比か回答検知に引っかかる。
public struct RefinementGuard: Sendable {

    public enum Rejection: Sendable, Equatable {
        case empty
        case lengthRatio(Double)
        case scriptShift
        case unrequestedMarkdown
        case answeredQuestion
        case contentDrift(retained: Double)
        case numberMismatch([String])
        case refusal

        /// ログに出してよい短い識別子。
        ///
        /// **`String(describing:)` を直接ログに流さないこと。**
        /// `numberMismatch` は発話から抽出した数値そのものを持つため、
        /// そのまま `.public` で出すと電話番号・金額・住所の番地が
        /// システムログに残る。件数だけを出す。
        /// 画面に出す文言（`TextRefiner.describe`）とは意図的に別物にしてある。
        public var logCode: String {
            switch self {
            case .empty: "empty"
            case .lengthRatio(let v): String(format: "lengthRatio(%.2f)", v)
            case .scriptShift: "scriptShift"
            case .unrequestedMarkdown: "unrequestedMarkdown"
            case .answeredQuestion: "answeredQuestion"
            case .contentDrift(let r): String(format: "contentDrift(%.2f)", r)
            case .numberMismatch(let n): "numberMismatch(\(n.count)件)"
            case .refusal: "refusal"
            }
        }
    }

    public enum Verdict: Sendable, Equatable {
        case accept(String)
        case reject(Rejection)
    }

    public init() {}

    public func evaluate(raw: String, candidate: String,
                         policy: GuardPolicy, nonce: String) -> Verdict {
        let repaired = Self.repair(candidate, nonce: nonce, rawHadFence: raw.contains("```"))
        if repaired.isEmpty { return .reject(.empty) }

        // 長さ。要約（短すぎ）と「質問に答えた」（長すぎ）を捕まえる。
        //
        // **2 つの基準の和集合**であって、どちらか一方に切り替えるのではない。
        // かつては「20 文字未満なら絶対差だけを見る」という排他分岐だったが、
        // それだと policy.lengthRatio の緩和が短文にまったく届かなかった。
        // 「英訳して」で 15 文字の日本語が 41 文字の英語になると、
        // 比率 2.7 は緩和後の許容範囲 (0.3...3.0) に収まっているのに、
        // 絶対差 26 が既定の slack 15 を超えて棄却されていた。
        // 日本語→英語は文字数が素直に 2〜3 倍になるので、短文ほどこれに当たる。
        let rawCount = raw.count, newCount = repaired.count
        let ratio = Double(newCount) / Double(max(rawCount, 1))
        let withinRatio = policy.lengthRatio.contains(ratio)
        // 絶対差は**短文専用の救済**。5 文字が 12 文字になるような、
        // 比率で見ると大きいが実害のない伸びを通すためにある。
        let withinSlack = rawCount < 20
            && abs(newCount - rawCount) <= policy.absoluteSlackForShortInput
        if !withinRatio, !withinSlack { return .reject(.lengthRatio(ratio)) }

        // 文字種。小さいモデルが勝手に英訳する失敗を捕まえる。
        if policy.requireSameScript, Self.japaneseRatio(raw) >= 0.3,
           Self.japaneseRatio(repaired) < 0.2 {
            return .reject(.scriptShift)
        }

        // 頼んでいない Markdown。
        if !policy.allowMarkdown, Self.hasMarkdown(repaired), !Self.hasMarkdown(raw) {
            return .reject(.unrequestedMarkdown)
        }

        // 質問に答えてしまった。**両側で同じ述語を使う**（片側だけだと誤検知する）。
        if policy.enforceQuestionShape,
           Self.endsAsQuestion(raw), !Self.endsAsQuestion(repaired) {
            return .reject(.answeredQuestion)
        }

        // 数値。**比率ではなく全部**。黙って壊すのが最も損害が大きい。
        if policy.enforceNumbers {
            let missing = Self.missingNumbers(raw: raw, candidate: repaired)
            if !missing.isEmpty { return .reject(.numberMismatch(missing)) }
        }

        // 固有名詞などの保持。1.0 にしないのは正当な誤認識修正があるため。
        if let threshold = policy.contentRetention {
            let retained = Self.retentionRatio(raw: raw, candidate: repaired)
            if retained < threshold { return .reject(.contentDrift(retained: retained)) }
        }

        if Self.looksLikeRefusal(repaired), !Self.looksLikeRefusal(raw) {
            return .reject(.refusal)
        }

        return .accept(repaired)
    }

    // MARK: - 修復（棄却の前に直せるものは直す）

    static func repair(_ text: String, nonce: String, rawHadFence: Bool) -> String {
        var s = text

        // 推論モデルの思考ブロック
        for tag in ["think", "reasoning"] {
            s = s.replacingOccurrences(
                of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "",
                options: .regularExpression)
        }

        // 区切りやプロンプトの断片が混ざった行を落とす
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("VOINP_TRANSCRIPT") && !$0.contains(nonce) }
            .joined(separator: "\n")

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // 全体を囲むコードフェンス（元の入力に無かった場合のみ）
        if !rawHadFence, s.hasPrefix("```"), s.hasSuffix("```") {
            var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 2 { lines.removeFirst(); lines.removeLast() }
            s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 前置き行
        let preambles = [
            #"^(以下|こちら)(が|は).{0,20}(です|になります|となります)[:：]?\s*$"#,
            #"^(Here(’|')?s|Sure|Certainly|Of course)\b.{0,60}[:：]\s*$"#,
        ]
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count >= 2, let first = lines.first,
           preambles.contains(where: { first.range(of: $0, options: .regularExpression) != nil }) {
            lines.removeFirst()
            s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return s
    }

    // MARK: - 判定の部品

    static func japaneseRatio(_ s: String) -> Double {
        let scalars = s.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return 0 }
        let jp = scalars.filter { v in
            (0x3040...0x309F).contains(v.value) ||   // ひらがな
            (0x30A0...0x30FF).contains(v.value) ||   // カタカナ
            (0x4E00...0x9FFF).contains(v.value)      // CJK 統合漢字
        }
        return Double(jp.count) / Double(scalars.count)
    }

    static func hasMarkdown(_ s: String) -> Bool {
        s.split(separator: "\n").contains { line in
            line.range(of: #"^\s*[-*+] "#, options: .regularExpression) != nil ||
            line.range(of: #"^#{1,6} "#, options: .regularExpression) != nil ||
            line.range(of: #"^\s*\|.*\|"#, options: .regularExpression) != nil
        }
    }

    /// 疑問文の終端か。
    /// **raw 側と candidate 側で必ず同じ述語を使うこと。**
    /// 日本語は「？」を使わず「〜ですか。」と書くほうが一般的なので、
    /// 片側だけ記号で判定すると正常な整形を棄却してしまう。
    static func endsAsQuestion(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "」』）)"))
        guard let last = t.last else { return false }
        if "？?".contains(last) { return true }
        let body = t.trimmingCharacters(in: CharacterSet(charactersIn: "。．.!！"))
        return ["か", "かな", "かね", "かい", "だろうか", "でしょうか", "ますか", "ですか", "のか"]
            .contains { body.hasSuffix($0) }
    }

    /// 消えた数値を探す。
    ///
    /// 注意点が 2 つある。どちらも実装時に踏んだ。
    /// - **桁区切りのカンマで分割しない。** `50,000` が `50` と `000` になり、
    ///   正しく `ご満悦` へ直した出力を「数値が消えた」と誤検知する。
    /// - **`Character.isNumber` を使わない。** 漢数字「京」「万」なども true を返すため、
    ///   「東京」の「京」を数値とみなしてしまう。ASCII 数字だけを見る。
    static func missingNumbers(raw: String, candidate: String) -> [String] {
        let normalize: (String) -> String = { s in
            String(s.unicodeScalars.map { v -> Character in
                // 全角数字を半角へ
                if (0xFF10...0xFF19).contains(v.value) {
                    return Character(UnicodeScalar(v.value - 0xFF10 + 0x30)!)
                }
                return Character(v)
            })
        }
        let a = normalize(raw), b = normalize(candidate)

        // ASCII 数字の連なり。桁区切りのカンマとピリオドは数値の一部として扱う。
        let pattern = #"[0-9][0-9,.]*"#
        let matches = a.ranges(of: pattern, options: .regularExpression)
            .map { String(a[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ",.")) }
            .filter { !$0.isEmpty }

        // 比較時は区切りを外して見る（"50,000" と "50000" を同じとみなす）。
        let bare: (String) -> String = { $0.replacingOccurrences(of: ",", with: "") }
        let candidateBare = bare(b)
        return Array(Set(matches.filter { !b.contains($0) && !candidateBare.contains(bare($0)) }))
            .sorted()
    }

    static func retentionRatio(raw: String, candidate: String) -> Double {
        var tokens: Set<String> = []
        // 連続する漢字（固有名詞になりやすい）
        var run = ""
        for ch in raw {
            if let v = ch.unicodeScalars.first, (0x4E00...0x9FFF).contains(v.value) {
                run.append(ch)
            } else {
                if run.count >= 2 { tokens.insert(run) }
                run = ""
            }
        }
        if run.count >= 2 { tokens.insert(run) }
        // 長めの ASCII トークン（製品名・略語）
        for t in raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        where t.count >= 3 && t.allSatisfy({ $0.isASCII }) {
            tokens.insert(String(t))
        }
        guard !tokens.isEmpty else { return 1.0 }
        let kept = tokens.filter { candidate.localizedCaseInsensitiveContains($0) }
        return Double(kept.count) / Double(tokens.count)
    }

    static func looksLikeRefusal(_ s: String) -> Bool {
        let patterns = ["申し訳", "お答えできません", "できかねます",
                        "I'm sorry", "I cannot", "I can't", "As an AI"]
        return patterns.contains { s.localizedCaseInsensitiveContains($0) }
    }
}

private extension String {
    /// 正規表現に一致する範囲をすべて返す。
    func ranges(of pattern: String, options: String.CompareOptions) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = startIndex
        while start < endIndex,
              let r = range(of: pattern, options: options, range: start..<endIndex) {
            result.append(r)
            start = r.upperBound > r.lowerBound ? r.upperBound : index(after: r.lowerBound)
        }
        return result
    }
}
