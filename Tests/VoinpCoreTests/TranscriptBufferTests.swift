import Testing
import Foundation
@testable import VoinpCore

@Suite("TranscriptBuffer")
struct TranscriptBufferTests {

    @Test("暫定結果は置換される。追記されない")
    func partialReplaces() {
        var b = TranscriptBuffer()
        b.apply(.partial("こんに"))
        b.apply(.partial("こんにちは"))
        #expect(b.snapshot().volatileTail == "こんにちは")
        #expect(b.snapshot().committed == "")
    }

    @Test("確定結果は追記され、暫定分は破棄される")
    func finalAppendsAndClearsVolatile() {
        var b = TranscriptBuffer()
        b.apply(.partial("こんに"))
        b.apply(.finalized(.init(text: "こんにちは。", audioRange: .zero(to: .seconds(1)))))
        #expect(b.snapshot().volatileTail == "")
        #expect(b.committed == "こんにちは。")
    }

    @Test("同じ区間の再確定は捨てる（文の二重化を防ぐ）")
    func duplicateRangeIgnored() {
        var b = TranscriptBuffer()
        b.apply(.finalized(.init(text: "テスト", audioRange: .zero(to: .seconds(1)))))
        b.apply(.finalized(.init(text: "テスト", audioRange: .zero(to: .seconds(1)))))
        #expect(b.committed == "テスト")
    }

    @Test("到着順が逆でも音声区間順に整列される")
    func outOfOrderSorted() {
        var b = TranscriptBuffer()
        b.apply(.finalized(.init(text: "後半", audioRange: .init(uncheckedBounds: (.seconds(2), .seconds(3))))))
        b.apply(.finalized(.init(text: "前半", audioRange: .zero(to: .seconds(1)))))
        #expect(b.committed == "前半後半")
    }

    @Test("連続する発話は捨てない（端点の共有は重なりではない）")
    func adjacentSegmentsBothKept() {
        var b = TranscriptBuffer()
        // 「こんにちは。」を 2 回。前の終わりと次の始まりが同時刻になりうる。
        b.apply(.finalized(.init(text: "こんにちは。",
                                 audioRange: Duration.seconds(0)...Duration.seconds(2))))
        b.apply(.finalized(.init(text: "こんにちは。",
                                 audioRange: Duration.seconds(2)...Duration.seconds(4))))
        #expect(b.committed == "こんにちは。こんにちは。",
                "同じ文言でも別の区間なら両方残す")
    }

    @Test("本当に食い込んでいる区間は捨てる")
    func trulyOverlappingDropped() {
        var b = TranscriptBuffer()
        b.apply(.finalized(.init(text: "こんにちは。",
                                 audioRange: Duration.seconds(0)...Duration.seconds(2))))
        b.apply(.finalized(.init(text: "こんにちは。",
                                 audioRange: Duration.seconds(1)...Duration.seconds(3))))
        #expect(b.committed == "こんにちは。", "再確定は二重化させない")
    }

    @Test("時刻情報のない確定結果は到着順に積む")
    func untimedAppends() {
        var b = TranscriptBuffer()
        b.apply(.finalized(.init(text: "A")))
        b.apply(.finalized(.init(text: "B")))
        #expect(b.committed == "AB")
    }

    @Test("finalText は前後の空白を落とす")
    func finalTextTrims() {
        var b = TranscriptBuffer()
        b.apply(.finalized(.init(text: "  こんにちは  ")))
        #expect(b.finalText == "こんにちは")
        #expect(!b.isEmpty)
    }

    @Test("ended: 確定があれば暫定を捨てる（推定を残して二重化しない）")
    func endedDropsVolatileWhenFinalsExist() {
        var b = TranscriptBuffer()
        b.apply(.finalized(.init(text: "確定分。")))
        b.apply(.partial("未確定"))
        b.apply(.ended(.init(fullText: "", locale: .init(identifier: "ja-JP"),
                             audioDuration: .seconds(1), providerID: "test")))
        #expect(b.snapshot().volatileTail == "")
        #expect(b.committed == "確定分。")
    }

    @Test("ended: 確定が 1 つも無ければ暫定を残す（発話を落とさない）")
    func endedKeepsVolatileWhenNoFinals() {
        var b = TranscriptBuffer()
        b.apply(.partial("未確定だけの発話"))
        b.apply(.ended(.init(fullText: "", locale: .init(identifier: "ja-JP"),
                             audioDuration: .seconds(1), providerID: "test")))
        // committed は空のままだが、挿入候補としては残る
        #expect(b.isEmpty, "確定テキストとしては空")
        #expect(b.bestEffortText == "未確定だけの発話", "挿入候補としては残る")
    }
}

extension ClosedRange where Bound == Duration {
    static func zero(to end: Duration) -> ClosedRange<Duration> { .seconds(0)...end }
}

@Suite("TranscriptBuffer — 取りこぼし防止")
struct TranscriptBufferFallbackTests {

    @Test("確定が来なくても暫定分を挿入候補として返す")
    func volatileSurvivesWhenNoFinal() {
        var b = TranscriptBuffer()
        b.apply(.partial("短い発話"))
        b.apply(.ended(.init(fullText: "", locale: .init(identifier: "ja-JP"),
                             audioDuration: .seconds(1), providerID: "t")))
        #expect(b.bestEffortText == "短い発話",
                "確定が無いからと発話を捨ててはいけない")
    }

    @Test("確定があれば暫定は捨てる（二重化しない）")
    func finalWinsOverVolatile() {
        var b = TranscriptBuffer()
        b.apply(.partial("こんにち"))
        b.apply(.finalized(.init(text: "こんにちは。")))
        b.apply(.ended(.init(fullText: "", locale: .init(identifier: "ja-JP"),
                             audioDuration: .seconds(1), providerID: "t")))
        #expect(b.bestEffortText == "こんにちは。")
    }

    @Test("何も無ければ空")
    func emptyStaysEmpty() {
        var b = TranscriptBuffer()
        b.apply(.ended(.init(fullText: "", locale: .init(identifier: "ja-JP"),
                             audioDuration: .zero, providerID: "t")))
        #expect(b.bestEffortText.isEmpty)
    }
}

@Suite("認識の断片除去")
struct StrayFragmentTests {

    /// 認識が区切りを誤ると、句読点の直後に単独の ASCII 文字が混ざることがある
    /// （「〜する。aゴルフは〜」）。日本語の発話に現れる余地がないので落とす。
    @Test("句読点直後の単独 ASCII 文字を落とす")
    func removesLoneLetterAfterPunctuation() {
        let input = "ゴルフをする。aゴルフは9時スタートで、終了は13時かな。a13時から昼食。"
        let out = TranscriptBuffer.removeStrayFragments(input)
        #expect(out == "ゴルフをする。ゴルフは9時スタートで、終了は13時かな。13時から昼食。")
    }

    @Test("本来の英単語は残す")
    func keepsRealWords() {
        // 2 文字以上は断片ではないので残す
        let input = "Kintoneのゴルフボールを買った。Slack に投稿する。"
        #expect(TranscriptBuffer.removeStrayFragments(input) == input)
    }

    @Test("英文は壊さない")
    func keepsEnglishText() {
        let input = "I went to Tokyo. A penguin was there."
        let out = TranscriptBuffer.removeStrayFragments(input)
        #expect(out.contains("I went to Tokyo"), "英文の単独 I や A を壊さないこと")
    }

    @Test("空文字でも落ちない")
    func handlesEmpty() {
        #expect(TranscriptBuffer.removeStrayFragments("") == "")
    }
}
