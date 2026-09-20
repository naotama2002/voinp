import Testing
import Foundation
@testable import VoinpCore

/// 読みの取得と正規化。
///
/// 期待値は 2026-09-20 に実機で測った値をそのまま置いている。
/// **推測で書いた期待値を置かないこと。** ここが崩れると候補生成が静かに劣化する。
@Suite("読みの取得と正規化")
struct JapaneseReadingTests {

    @Test("漢字交じり文から読みが取れる", arguments: [
        ("銀魂", "ぎんたま"), ("均等の", "きんとうの"), ("仕様", "しよう"),
        ("異動", "いどう"), ("東京", "とうきょう"),
    ])
    func readsKanji(_ input: String, _ expected: String) {
        #expect(JapaneseReading.reading(of: input) == expected)
    }

    @Test("ASCII が混ざっても落ちない")
    func survivesMixedScript() {
        // ラテン語のトークンは transcription 属性を持たない。
        // そこで諦める実装だと、この文がまるごと空になる。
        let r = JapaneseReading.reading(of: "kintone のレコード")
        #expect(!r.isEmpty)
        #expect(r.contains("のれこおど"))
    }

    @Test("空文字は空文字")
    func handlesEmpty() {
        #expect(JapaneseReading.reading(of: "") == "")
        #expect(JapaneseReading.comparable("") == "")
    }

    @Test("カタカナ・濁点・長音・小書きを均す", arguments: [
        ("キントーン", "きんとおん"),   // カタカナ + 長音
        ("ガルーン", "かるうん"),       // 濁点 + 長音
        ("ぎんたま", "きんたま"),       // 濁点
        ("しゃちょう", "しやちよう"),   // 小書き
        ("パン", "はん"),               // 半濁点
    ])
    func normalizes(_ input: String, _ expected: String) {
        #expect(JapaneseReading.normalize(input) == expected)
    }

    /// **`ー` を自前で展開するコードは、普通は実行されない。**
    ///
    /// `kCFStringTransformHiraganaKatakana` が先に母音へ開いてしまうため
    /// （実測: `きんとーん` も変換だけで `きんとおん` になる）。
    /// 自前の展開を消してもテストが 1 件も落ちず、**死んだコードだと分かった**。
    /// 依存しているのは変換側の挙動なので、そちらを固定する。
    @Test("長音は変換の時点で母音に開かれている（自前の展開ではない）")
    func transformItselfExpandsProlongedMark() {
        let m = NSMutableString(string: "きんとーん") as CFMutableString
        CFStringTransform(m, nil, kCFStringTransformHiraganaKatakana, true)
        #expect(m as String == "きんとおん", "ここが変わったら normalize の前提が崩れる")
    }

    @Test("ハイフンで書いた読みも母音に開く（自前の展開が効くのはここ）", arguments: [
        ("きんと-ん", "きんとおん"), ("きんと－ん", "きんとおん"),
    ])
    func expandsAsciiHyphen(_ input: String, _ expected: String) {
        #expect(JapaneseReading.normalize(input) == expected)
    }

    @Test("同音異義語は完全一致になる", arguments: [
        ("仕様", "使用"), ("移動", "異動"), ("公開", "後悔"), ("確立", "確率"),
    ])
    func homophonesMatchExactly(_ a: String, _ b: String) {
        let x = JapaneseReading.comparable(a), y = JapaneseReading.comparable(b)
        #expect(JapaneseReading.distance(x, y) == 0, "\(a)(\(x)) と \(b)(\(y))")
        #expect(JapaneseReading.similarity(x, y) == 1.0)
    }

    @Test("無関係な語は似ていない")
    func unrelatedWordsAreFarApart() {
        let sim = JapaneseReading.similarity(
            JapaneseReading.comparable("移動"), JapaneseReading.comparable("ガルーン"))
        #expect(sim < 0.35, "実測 0.25。ここが上がると誤検出が増える")
    }

    @Test("固有名詞の取り違えは中間の値になる")
    func misheardProperNounSitsInTheMiddle() {
        // 実測: 銀魂/キントーン = 0.40、均等/キントーン = 0.60。
        // 下限 0.35 と無関係語 0.25 の間が狭いことを、この 2 件で固定しておく。
        let target = JapaneseReading.comparable("キントーン")
        let a = JapaneseReading.similarity(JapaneseReading.comparable("銀魂"), target)
        let b = JapaneseReading.similarity(JapaneseReading.comparable("均等"), target)
        #expect(a >= TermCandidateFinder.defaultMinimumSimilarity)
        #expect(b > a)
    }
}

@Suite("辞書の 1 行を読む")
struct TermHintParsingTests {

    @Test("読みを書かなくても使える（既存の辞書を壊さない）")
    func plainTermStillWorks() {
        let t = TermHint.parse("サイボウズ")
        #expect(t?.text == "サイボウズ")
        #expect(t?.reading == nil)
        #expect(t?.comparableReading == "さいほうす")
    }

    @Test("読みを添えられる", arguments: [
        "kintone きんとーん", "kintone,きんとーん", "kintone\tきんとーん",
    ])
    func readingCanBeGiven(_ line: String) {
        let t = TermHint.parse(line)
        #expect(t?.text == "kintone")
        #expect(t?.comparableReading == "きんとおん")
    }

    @Test("読みを書かない ASCII 語はローマ字読みになる（だから読みが要る）")
    func asciiWithoutReadingIsRomaji() {
        #expect(TermHint.parse("kintone")?.comparableReading == "きんとね")
        // 同じ語なのに、読みの有無で別物になる。これが読みを書く理由。
        #expect(TermHint.parse("kintone")?.comparableReading
                != TermHint.parse("kintone きんとーん")?.comparableReading)
    }

    @Test("空行は無視する")
    func skipsBlankLines() {
        #expect(TermHint.parse("") == nil)
        #expect(TermHint.parse("   ") == nil)
    }
}

/// 候補の生成。
///
/// **この段は recall 寄りに作ってある。** 拾いすぎた分は後段の判定器が落とす
/// （実測で、誤りでない箇所は元の表記が 1.00 で選ばれた）。
/// 逆に、ここで落とした候補は後段からは絶対に復活しない。
@Suite("辞書からの候補生成")
struct TermCandidateFinderTests {

    let terms = [
        TermHint("kintone", reading: "きんとーん"),
        TermHint("Garoon", reading: "がるーん"),
        TermHint("サイボウズ"),
        TermHint("グループウェア"),
    ]

    private func best(_ text: String) -> (String, String)? {
        guard let m = TermCandidateFinder.matches(in: text, terms: terms).first else { return nil }
        return (m.recognized, m.best.term)
    }

    @Test("N-best に無かった誤変換を辞書側から拾える")
    func findsWhatTheEngineNeverOffered() {
        // 実測で、この語のエンジン候補は本命 1 件のみだった。
        // 再ランキングでは救えない。辞書から供給するしかない。
        let r = best("銀魂のレコードを更新します。")
        #expect(r?.0 == "銀魂")
        #expect(r?.1 == "kintone")
    }

    @Test("助詞を巻き込まない")
    func trimsParticles() {
        let m = TermCandidateFinder.matches(in: "均等のアプリを作ります", terms: terms)
        #expect(m.first?.recognized == "均等", "「均等の」だと差し替えで助詞まで消える")
    }

    @Test("部分的に落ちた固有名詞も拾える")
    func findsPartiallyDroppedTerm() {
        let r = best("ルーンのスケジュールも確認してください")
        #expect(r?.0 == "ルーン")
        #expect(r?.1 == "Garoon")
    }

    // MARK: - 出してはいけない場面

    @Test("誤りのない文では何も出さない")
    func silentOnCleanText() {
        #expect(TermCandidateFinder.matches(in: "今日の天気は晴れです。", terms: terms).isEmpty)
    }

    @Test("既に正しい表記が出ているなら提案しない")
    func neverSuggestsWhatIsAlreadyThere() {
        let m = TermCandidateFinder.matches(in: "サイボウズのグループウェアを使います", terms: terms)
        #expect(m.isEmpty, "正しく認識できている箇所を触らせない")
    }

    @Test("音数が違いすぎるものは候補にしない")
    func rejectsDifferentMoraCount() {
        // 「移動」(いとう=3) と「サイボウズ」(さいほうす=5)。
        // 類似度だけだと 0.40 で通ってしまう。誤変換は音を保つので音数で落とす。
        #expect(TermCandidateFinder.matches(in: "会議室を移動してください。", terms: terms).isEmpty)
    }

    @Test("辞書が空なら何もしない")
    func emptyDictionaryYieldsNothing() {
        #expect(TermCandidateFinder.matches(in: "銀魂のレコード", terms: []).isEmpty)
    }

    // MARK: - 出しすぎない

    @Test("同じ箇所について重ねて提案しない")
    func picksOneSpanPerPlace() {
        let m = TermCandidateFinder.matches(in: "銀魂のレコードを更新します。", terms: terms)
        for i in m.indices {
            for j in m.indices where i < j {
                #expect(!m[i].range.overlaps(m[j].range), "同じ箇所に矛盾した差し替えを言わせない")
            }
        }
    }

    @Test("1 回の発話で後段へ回す箇所に上限がある")
    func capsMatchesPerUtterance() {
        let text = "銀魂と均等とルーンと銀魂と均等とルーンと銀魂と均等"
        let m = TermCandidateFinder.matches(in: text, terms: terms, maxMatches: 2)
        #expect(m.count <= 2)
    }

    @Test("候補は類似度の高い順に並ぶ")
    func suggestionsAreRanked() {
        let m = TermCandidateFinder.matches(in: "銀魂のレコード", terms: terms)
        for match in m {
            let sims = match.suggestions.map(\.similarity)
            #expect(sims == sims.sorted(by: >))
            #expect(match.best.similarity == sims.first)
        }
    }

    @Test("見つけた範囲が元の文の実際の位置を指している")
    func rangesPointAtTheRealText() {
        let text = "銀魂のレコードを更新します。"
        for m in TermCandidateFinder.matches(in: text, terms: terms) {
            #expect(String(text[m.range]) == m.recognized,
                    "範囲がずれていると、差し替えで別の箇所を壊す")
        }
    }
}
