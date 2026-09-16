import Foundation
import Testing
import VoinpCore
@testable import VoinpProviders

/// Realtime のイベントを voinp の意味論へ翻訳できているか。
///
/// **ここが実装の要。** Realtime の `delta` は追記分、voinp の `.partial` は置換。
/// 意味論が逆なので、素通しすると HUD に最後の断片しか出ない。
@Suite("Realtime のイベント変換")
struct RealtimeTranscriptAssemblerTests {

    /// 追記の delta を、置換の partial に積み上げられること。
    @Test("連続した delta は累積して partial になる")
    func deltasAccumulate() {
        var a = RealtimeTranscriptAssembler()
        #expect(a.ingest(.transcriptDelta(itemID: "i1", delta: "今日は")) == [.partial("今日は")])
        #expect(a.ingest(.transcriptDelta(itemID: "i1", delta: "いい")) == [.partial("今日はいい")])
        #expect(a.ingest(.transcriptDelta(itemID: "i1", delta: "天気")) == [.partial("今日はいい天気")])
    }

    @Test("completed は全文を確定として出す")
    func completedFinalizes() {
        var a = RealtimeTranscriptAssembler()
        _ = a.ingest(.transcriptDelta(itemID: "i1", delta: "今日は"))
        let out = a.ingest(.transcriptCompleted(itemID: "i1", transcript: "今日はいい天気です。"))
        #expect(out.first == .finalized(TranscriptSegment(text: "今日はいい天気です。")))
        #expect(out.last == .partial(""), "確定した分は暫定から消えること")
        #expect(a.hasCommitted)
    }

    /// 同じターンを 2 回確定させると、文が二重に挿入される。
    @Test("同じ item_id の completed は 1 度しか確定しない")
    func duplicateCompletedIgnored() {
        var a = RealtimeTranscriptAssembler()
        _ = a.ingest(.transcriptCompleted(itemID: "i1", transcript: "こんにちは"))
        #expect(a.ingest(.transcriptCompleted(itemID: "i1", transcript: "こんにちは")).isEmpty)
    }

    /// **空の確定を出すと発話が消える。**
    /// TranscriptBuffer は `.finalized` を受けると volatileTail を捨てるので、
    /// 空で出すと bestEffortText が空になる。
    @Test("空の completed で暫定を殺さない")
    func emptyCompletedKeepsPending() {
        var a = RealtimeTranscriptAssembler()
        _ = a.ingest(.transcriptDelta(itemID: "i1", delta: "あ"))
        _ = a.ingest(.transcriptDelta(itemID: "i2", delta: "い"))
        let out = a.ingest(.transcriptCompleted(itemID: "i1", transcript: ""))
        #expect(!out.contains { if case .finalized = $0 { true } else { false } },
                "空の確定を出さないこと")
        #expect(out == [.partial("い")], "残りの暫定は生きていること")
    }

    @Test("複数ターンが交互に来ても到着順を保つ")
    func interleavedTurnsKeepOrder() {
        var a = RealtimeTranscriptAssembler()
        _ = a.ingest(.transcriptDelta(itemID: "i1", delta: "A"))
        _ = a.ingest(.transcriptDelta(itemID: "i2", delta: "B"))
        let out = a.ingest(.transcriptDelta(itemID: "i1", delta: "C"))
        #expect(out == [.partial("ACB")], "i1 が先に現れたので i1 が前")
    }

    @Test("failed は該当ターンだけを捨てる")
    func failedDropsOnlyThatTurn() {
        var a = RealtimeTranscriptAssembler()
        _ = a.ingest(.transcriptDelta(itemID: "i1", delta: "壊れた"))
        _ = a.ingest(.transcriptDelta(itemID: "i2", delta: "無事"))
        #expect(a.ingest(.transcriptFailed(itemID: "i1")) == [.partial("無事")])
    }

    /// サーバーが completed を返さないまま切れることがある。捨てると発話が消える。
    @Test("確定が来ないまま終わっても溜まった分を拾う")
    func finishRecoversPending() {
        var a = RealtimeTranscriptAssembler()
        _ = a.ingest(.transcriptDelta(itemID: "i1", delta: "確定が来なかった"))
        #expect(a.finish() == [.finalized(TranscriptSegment(text: "確定が来なかった"))])
    }

    @Test("何も無ければ finish は何も出さない")
    func finishEmpty() {
        var a = RealtimeTranscriptAssembler()
        #expect(a.finish().isEmpty)
    }

    @Test("セッション制御イベントは何も出さない")
    func controlEventsProduceNothing() {
        var a = RealtimeTranscriptAssembler()
        for e in [RealtimeWireEvent.sessionCreated, .sessionUpdated, .ignored("x")] {
            #expect(a.ingest(e).isEmpty)
        }
    }
}

/// `TranscriptBuffer` に流し込んだときに、実際に正しい文字列になるか。
///
/// **この結合でしか確かめられないことがある。** アセンブラ単体では
/// 「置換に変換できているか」は分かるが、バッファ側の規約
/// （確定が来たら暫定を捨てる）と噛み合っているかは分からない。
@Suite("TranscriptBuffer との結合")
struct RealtimeAssemblerBufferIntegrationTests {

    private func run(_ events: [RealtimeWireEvent]) -> TranscriptBuffer {
        var assembler = RealtimeTranscriptAssembler()
        var buffer = TranscriptBuffer()
        for e in events {
            for out in assembler.ingest(e) { buffer.apply(out) }
        }
        return buffer
    }

    @Test("delta だけなら暫定として見える")
    func deltasAreVolatile() {
        let b = run([
            .transcriptDelta(itemID: "i1", delta: "今日は"),
            .transcriptDelta(itemID: "i1", delta: "いい天気"),
        ])
        #expect(b.snapshot().volatileTail == "今日はいい天気")
        #expect(b.snapshot().committed.isEmpty)
    }

    @Test("completed で確定に移り、暫定が消える")
    func completedMovesToCommitted() {
        let b = run([
            .transcriptDelta(itemID: "i1", delta: "今日は"),
            .transcriptCompleted(itemID: "i1", transcript: "今日はいい天気です。"),
        ])
        #expect(b.snapshot().committed == "今日はいい天気です。")
        #expect(b.snapshot().volatileTail.isEmpty)
    }

    /// 2 ターン分が重複せず連結されること。
    @Test("複数ターンが重複せず連結される")
    func twoTurnsConcatenate() {
        let b = run([
            .transcriptDelta(itemID: "i1", delta: "一つ目"),
            .transcriptCompleted(itemID: "i1", transcript: "一つ目です。"),
            .transcriptDelta(itemID: "i2", delta: "二つ目"),
            .transcriptCompleted(itemID: "i2", transcript: "二つ目です。"),
        ])
        #expect(b.bestEffortText == "一つ目です。二つ目です。")
    }

    /// 確定が来ないまま終わっても、話した内容が取れること。
    @Test("確定が来なくても bestEffortText は空にならない")
    func bestEffortSurvivesMissingCompleted() {
        var assembler = RealtimeTranscriptAssembler()
        var buffer = TranscriptBuffer()
        for out in assembler.ingest(.transcriptDelta(itemID: "i1", delta: "確定が来ない")) {
            buffer.apply(out)
        }
        for out in assembler.finish() { buffer.apply(out) }
        #expect(buffer.bestEffortText == "確定が来ない")
    }
}
