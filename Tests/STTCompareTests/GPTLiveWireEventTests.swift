import Foundation
import Testing
@testable import STTCompare

/// GPT-Live のメッセージ解釈。
@Suite("GPT-Live のメッセージ")
struct GPTLiveWireEventTests {

    private func decode(_ object: [String: Any]) -> GPTLiveWireEvent {
        GPTLiveWireEvent.decode(try! JSONSerialization.data(withJSONObject: object))
    }

    @Test("session.started を認識する")
    func started() {
        #expect(decode(["type": "session.started"]) == .sessionStarted)
    }

    @Test("入力の書き起こしを取り出す")
    func inputTranscript() {
        #expect(decode(["type": "session.input_transcript.delta", "delta": "今日は"])
                == .inputTranscriptDelta("今日は"))
    }

    /// **モデルが喋った内容は捨てる。**
    /// 比べたいのはユーザーの発話であって、モデルの応答ではない。
    /// 混ぜると、喋り返した分が書き起こしに紛れ込む。
    @Test("モデルの発話は捨てる")
    func dropsOutputTranscript() {
        #expect(decode(["type": "session.output_transcript.delta", "delta": "こんにちは"])
                == .ignored)
    }

    @Test("エラーを取り出す")
    func error() {
        #expect(decode(["type": "error", "error": ["message": "rate limited"]])
                == .error("rate limited"))
    }

    @Test("知らないメッセージは無視する")
    func unknown() {
        #expect(decode(["type": "session.output_audio.delta"]) == .ignored)
        #expect(GPTLiveWireEvent.decode(Data("not json".utf8)) == .ignored)
    }

    /// 喋り返さないよう頼むが、**保証はない**（抑止する設定が文書化されていない）。
    @Test("喋らないよう指示を入れる")
    func instructsNotToSpeak() {
        let root = (try? JSONSerialization.jsonObject(with: GPTLiveConfig().startPayload()))
            as? [String: Any]
        let session = root?["session"] as? [String: Any]
        #expect((session?["instructions"] as? String)?.contains("Do not speak") == true)
        #expect(root?["type"] as? String == "session.start")
    }
}

/// **3 つのプロトコルの差を 1 箇所に集めた検査。**
///
/// 比較ツールの核心はここ。差分の意味を取り違えると、
/// 片方は断片しか出ず、もう片方は同じ文字が二重に並ぶ。
/// どちらも「エンジンの精度が悪い」ように見えてしまい、比較そのものが嘘になる。
@Suite("3 プロトコルの差")
struct ProtocolDifferenceTests {

    /// 暫定結果の意味。**Gemini だけが全文で、他は追記。**
    @Test("暫定の意味が Gemini だけ違う")
    func interimSemantics() {
        // Gemini: 毎回その時点の全文が来る
        let g1 = GeminiLiveWireEvent.decode(try! JSONSerialization.data(withJSONObject:
            ["serverContent": ["interimInputTranscription": ["text": "今日は"]]]))
        let g2 = GeminiLiveWireEvent.decode(try! JSONSerialization.data(withJSONObject:
            ["serverContent": ["interimInputTranscription": ["text": "今日はいい天気"]]]))
        #expect(g1 == .interimTranscript("今日は"))
        #expect(g2 == .interimTranscript("今日はいい天気"),
                "全文なのでそのまま .partial に流せる")

        // GPT-Live: 追記分が来る。累積が要る
        let p1 = GPTLiveWireEvent.decode(try! JSONSerialization.data(withJSONObject:
            ["type": "session.input_transcript.delta", "delta": "今日は"]))
        let p2 = GPTLiveWireEvent.decode(try! JSONSerialization.data(withJSONObject:
            ["type": "session.input_transcript.delta", "delta": "いい天気"]))
        #expect(p1 == .inputTranscriptDelta("今日は"))
        #expect(p2 == .inputTranscriptDelta("いい天気"),
                "追記分なので累積しないと『いい天気』しか出ない")
    }

    /// サンプルレート。**揃っていない。**
    /// 取り込みから各エンジンへ落とす。水増しはしない。
    @Test("要求するサンプルレートが違う")
    func sampleRatesDiffer() {
        #expect(GeminiLiveConfig.sampleRate == 16_000)
        #expect(GPTLiveConfig.sampleRate == 24_000)
    }
}
