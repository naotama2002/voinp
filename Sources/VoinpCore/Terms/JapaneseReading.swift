import Foundation

/// 漢字交じり文から読み（ひらがな）を取り、比較できる形に均す。
///
/// 2026-09-20 に実測して分かったこと:
/// - `CFStringTokenizer` の `LatinTranscription` → `CFStringTransform` で読みは取れる
/// - **ラテン語のトークンは属性を持たない。** そこで `nil` を返して全体を諦めると、
///   ASCII 混じりの文がまるごと判定不能になる。素通しすること
/// - 読みは 1 つに決め打ちされる（`明日` は「あす」。「あした」は出ない）
public enum JapaneseReading {

    /// 読みをひらがなで返す。取れない部分は元の文字をそのまま残す。
    public static func reading(of text: String) -> String {
        guard !text.isEmpty else { return "" }
        let cf = text as CFString
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cf, CFRangeMake(0, CFStringGetLength(cf)),
            kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)

        var out = ""
        let ns = text as NSString
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                let m = NSMutableString(string: latin) as CFMutableString
                CFStringTransform(m, nil, kCFStringTransformLatinHiragana, false)
                out += m as String
            } else {
                out += ns.substring(with: NSRange(location: r.location, length: r.length))
            }
        }
        return out
    }

    /// 比較用に均す。**表記の揺れで別物に見えるのを防ぐ。**
    ///
    /// `キントーン` と `きんとおん` と `ギントーン` を同じ形にする。
    /// 濁点・小書き・長音・カタカナは、音としては近いのに符号が違うだけなので、
    /// ここで潰さないと編集距離が実態より大きく出る。
    public static func normalize(_ kana: String) -> String {
        // カタカナ → ひらがな
        let m = NSMutableString(string: kana) as CFMutableString
        CFStringTransform(m, nil, kCFStringTransformHiraganaKatakana, true)
        // 濁点・半濁点は結合文字に分解してから落とす
        let stripped = (m as String).decomposedStringWithCanonicalMapping
            .unicodeScalars.filter { $0.value != 0x3099 && $0.value != 0x309A }
        var base = String(String.UnicodeScalarView(stripped))
        base = base.precomposedStringWithCanonicalMapping

        var out = ""
        for ch in base {
            if let plain = Self.smallToPlain[ch] {
                out.append(plain)
            } else if ch == "ー" || ch == "-" || ch == "－" {
                // **`ー` はここへ来ないのが普通。**
                // 上の `kCFStringTransformHiraganaKatakana` が先に母音へ開いてしまう
                // （`キントーン` も `きんとーん` も、変換の時点で `きんとおん` になる）。
                // ここが実際に効くのは、辞書に半角/全角ハイフンで読みを書いた場合。
                // 展開できなければ落とす（残すと 1 文字ぶん損をする）。
                if let last = out.last, let vowel = Self.vowel(of: last) { out.append(vowel) }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// 均した読みどうしの距離。
    public static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1]
                    : Swift.min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// 0（無関係）〜 1（一致）。長さで割るので、短い語どうしが不当に似て見えない。
    public static func similarity(_ a: String, _ b: String) -> Double {
        let longest = Swift.max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return 1 - Double(distance(a, b)) / Double(longest)
    }

    /// 表記から、比較に使える形の読みを一気に作る。
    public static func comparable(_ text: String) -> String {
        normalize(reading(of: text))
    }

    // MARK: - 表

    private static let smallToPlain: [Character: Character] = [
        "ぁ": "あ", "ぃ": "い", "ぅ": "う", "ぇ": "え", "ぉ": "お",
        "っ": "つ", "ゃ": "や", "ゅ": "ゆ", "ょ": "よ", "ゎ": "わ",
    ]

    /// 清音ひらがなの母音。濁点は除去済みの前提。
    private static func vowel(of ch: Character) -> Character? {
        if "あかさたなはまやらわ".contains(ch) { return "あ" }
        if "いきしちにひみり".contains(ch) { return "い" }
        if "うくすつぬふむゆる".contains(ch) { return "う" }
        if "えけせてねへめれ".contains(ch) { return "え" }
        if "おこそとのほもよろを".contains(ch) { return "お" }
        return nil
    }
}
