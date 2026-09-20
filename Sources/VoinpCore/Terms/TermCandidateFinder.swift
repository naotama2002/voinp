import Foundation

/// 認識テキストの中から、**辞書語の誤変換らしき箇所**を見つけて候補を作る。
///
/// ## なぜ要るか
///
/// 実測（[docs/08](../../../docs/08-editing-and-learning.md)）で、
/// エンジンが返す N-best に正解が入っていない場面が多いと分かった。
/// `銀魂`（正: kintone）の候補は本命 1 件だけで、選び直す余地が無い。
///
/// **エンジンが返さない候補を、辞書側から供給する。**
/// 判定器（Jev など）は選ぶことしかできないので、選択肢が無ければ何もできない。
///
/// ## ここは通信しない
///
/// 読みの取得も距離も全部ローカルで完結する。外へ出す前に、
/// **出す価値のある箇所だけに絞る**のがこの型の役目。
public enum TermCandidateFinder {

    public struct Suggestion: Equatable, Sendable {
        public let term: String
        public let similarity: Double
        public init(term: String, similarity: Double) {
            self.term = term; self.similarity = similarity
        }
    }

    public struct Match: Equatable, Sendable {
        /// 認識テキスト中の位置。
        public let range: Range<String.Index>
        /// そこに出ている文字列。
        public let recognized: String
        /// 類似度の高い順。**空にならない**（空なら Match を作らない）。
        public let suggestions: [Suggestion]

        public var best: Suggestion { suggestions[0] }
    }

    /// 既定の下限。実測値から決めた:
    ///
    /// | 組 | 類似度 |
    /// |---|---|
    /// | 仕様 / 使用（同音異義） | 1.00 |
    /// | 均等の / キントーン | 0.60 |
    /// | 銀魂 / キントーン | **0.40** |
    /// | 移動 / ガルーン（無関係） | 0.25 |
    ///
    /// 0.40 と 0.25 の間しか余裕がない。**閾値だけに頼らず、上位いくつかを返して
    /// 最終判断は後段に任せる**設計にしてある。
    public static let defaultMinimumSimilarity = 0.35

    /// 1 つの語を何トークンまでの塊として探すか。
    /// 「均等 の」のように分かれるので 1 では足りず、広げすぎると無関係な塊が当たる。
    private static let maxTokensPerSpan = 3

    /// 1 回の発話から後段へ回す箇所の上限。
    /// 判定器に何十件も聞くのは、費用より**誤って直される機会を増やす**ほうが問題。
    public static let defaultMaxMatches = 5

    public static func matches(
        in text: String,
        terms: [TermHint],
        minimumSimilarity: Double = defaultMinimumSimilarity,
        maxSuggestions: Int = 3,
        maxMatches: Int = defaultMaxMatches
    ) -> [Match] {
        guard !text.isEmpty, !terms.isEmpty else { return [] }

        let prepared = terms.compactMap { term -> (TermHint, String)? in
            let r = term.comparableReading
            return r.isEmpty ? nil : (term, r)
        }
        guard !prepared.isEmpty else { return [] }

        var found: [Match] = []
        for span in spans(of: text) {
            let piece = String(text[span])
            let reading = JapaneseReading.comparable(piece)
            guard !reading.isEmpty else { continue }

            let ranked = prepared
                // 既にその表記で出ているなら直す必要がない。
                .filter { $0.0.text != piece }
                // **音数が大きく違うものは誤変換ではない。**
                // 誤変換は音を保つので、音数はほぼ変わらない
                // （同音異義は 0、固有名詞の取り違えでも 1 程度）。
                // これで「移動(いとう)」が「サイボウズ(さいほうす)」に
                // 0.40 で当たる、という形の誤検出が消える。
                .filter { abs($0.1.count - reading.count) <= ($0.1.count >= 6 ? 2 : 1) }
                .map { Suggestion(term: $0.0.text,
                                  similarity: JapaneseReading.similarity(reading, $0.1)) }
                .filter { $0.similarity >= minimumSimilarity }
                .sorted { $0.similarity > $1.similarity }
                .prefix(maxSuggestions)

            guard !ranked.isEmpty else { continue }
            found.append(Match(range: span, recognized: piece, suggestions: Array(ranked)))
        }

        return pickNonOverlapping(found, limit: maxMatches)
    }

    /// 重なり合う候補から、**よく似ているものを優先して**重複しない集合を選ぶ。
    ///
    /// 「均等」と「均等の」は両方当たる。両方を後段へ渡すと、
    /// 同じ箇所について矛盾した差し替えを 2 回言われることになる。
    private static func pickNonOverlapping(_ all: [Match], limit: Int) -> [Match] {
        let ordered = all.sorted {
            $0.best.similarity != $1.best.similarity
                ? $0.best.similarity > $1.best.similarity
                : $0.recognized.count > $1.recognized.count   // 同点なら長いほうを採る
        }
        var taken: [Match] = []
        for m in ordered where !taken.contains(where: { $0.range.overlaps(m.range) }) {
            taken.append(m)
            if taken.count >= limit { break }
        }
        return taken.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// 単語境界で切り、連続する 1〜3 トークンの塊を返す。
    private static func spans(of text: String) -> [Range<String.Index>] {
        let cf = text as CFString
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cf, CFRangeMake(0, CFStringGetLength(cf)),
            kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)

        var tokens: [Range<String.Index>] = []
        let ns = text as NSString
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let nsRange = NSRange(location: r.location, length: r.length)
            guard let range = Range(nsRange, in: text) else { continue }
            let piece = ns.substring(with: nsRange)
            // 句読点や空白だけのトークンは語の一部にならない。
            guard piece.rangeOfCharacter(from: .alphanumerics.union(.symbols)) != nil
                    || piece.unicodeScalars.contains(where: { $0.value > 0x2FFF })
            else { continue }
            tokens.append(range)
        }

        // **助詞で始まる／終わる塊を落とす。**
        // 「を更新」が Garoon に 0.40 で当たる、という形の誤検出がこれで消える。
        // 「銀魂の」も「銀魂」に締まるので、差し替えたときに助詞を巻き込まない。
        var out: [Range<String.Index>] = []
        for i in tokens.indices {
            for n in 1...maxTokensPerSpan where i + n <= tokens.count {
                var lo = i, hi = i + n - 1
                while lo <= hi, isFunctionWord(ns, tokens[lo], in: text) { lo += 1 }
                while hi >= lo, isFunctionWord(ns, tokens[hi], in: text) { hi -= 1 }
                guard lo <= hi else { continue }
                let range = tokens[lo].lowerBound..<tokens[hi].upperBound
                if !out.contains(range) { out.append(range) }
            }
        }
        return out
    }

    /// 助詞・助動詞らしいトークンか。
    /// **ひらがな 1〜2 文字の機能語だけ**を落とす。固有名詞を巻き込まないよう狭く取る。
    private static func isFunctionWord(
        _ ns: NSString, _ range: Range<String.Index>, in text: String
    ) -> Bool {
        let piece = String(text[range])
        guard piece.count <= 2 else { return false }
        return Self.functionWords.contains(piece)
    }

    private static let functionWords: Set<String> = [
        "を", "が", "は", "に", "で", "と", "も", "の", "へ", "や", "か", "ね", "よ",
        "な", "し", "て", "た", "です", "ます", "から", "まで", "より", "など", "この",
        "その", "あの", "する", "した", "して", "ある", "いる", "れる", "られ",
    ]
}
