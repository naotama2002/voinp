import Foundation
import Testing
@testable import STTCompare

/// Gemini Live のメッセージ解釈。
///
/// **暫定結果の意味が OpenAI と逆。** ここを取り違えると、
/// 片方は断片しか出ず、もう片方は同じ文字が二重に並ぶ。
///
/// | | OpenAI Realtime | Gemini Live |
/// |---|---|---|
/// | 暫定 | `delta`（**追記分**） | `interimInputTranscription`（**その時点の全文**） |
@Suite("Gemini Live のメッセージ")
struct GeminiLiveWireEventTests {

    private func decode(_ object: [String: Any]) -> GeminiLiveWireEvent {
        GeminiLiveWireEvent.decode(
            try! JSONSerialization.data(withJSONObject: object))
    }

    @Test("setupComplete を認識する")
    func setupComplete() {
        #expect(decode(["setupComplete": [:]]) == .setupComplete)
    }

    /// 暫定は**全文**。voinp の `.partial` は置換なので、そのまま流せる。
    @Test("暫定は全文として取り出す")
    func interim() {
        let e = decode(["serverContent":
            ["interimInputTranscription": ["text": "今日はいい天気"]]])
        #expect(e == .interimTranscript("今日はいい天気"))
    }

    @Test("確定を取り出す")
    func final() {
        let e = decode(["serverContent":
            ["inputTranscription": ["text": "今日はいい天気です。"]]])
        #expect(e == .finalTranscript("今日はいい天気です。"))
    }

    /// 同じメッセージに両方入っていたら確定を採る。
    /// 暫定を採ると、確定済みの文が暫定として出戻る。
    @Test("確定と暫定が同時に来たら確定を採る")
    func finalWinsOverInterim() {
        let e = decode(["serverContent": [
            "inputTranscription": ["text": "確定"],
            "interimInputTranscription": ["text": "暫定"],
        ]])
        #expect(e == .finalTranscript("確定"))
    }

    /// 空の確定で暫定を殺さない。
    /// 出すと `TranscriptBuffer` が暫定を捨て、話した内容が消える。
    @Test("空の確定は無視する")
    func emptyFinalIsIgnored() {
        let e = decode(["serverContent": ["inputTranscription": ["text": ""]]])
        #expect(e != .finalTranscript(""))
    }

    @Test("エラーを取り出す")
    func error() {
        #expect(decode(["error": ["message": "quota exceeded"]])
                == .error("quota exceeded"))
    }

    @Test("知らないメッセージは無視する")
    func unknownIsIgnored() {
        #expect(decode(["somethingElse": [:]]) == .ignored)
        #expect(GeminiLiveWireEvent.decode(Data("not json".utf8)) == .ignored)
    }
}

@Suite("Gemini Live の setup")
struct GeminiLiveConfigTests {

    private func setup(_ c: GeminiLiveConfig) -> [String: Any] {
        let root = (try? JSONSerialization.jsonObject(with: c.setupPayload()))
            as? [String: Any] ?? [:]
        return root["setup"] as? [String: Any] ?? [:]
    }

    /// **音声で返させない。** 比較したいのは文字起こしであって応答ではないし、
    /// 音声を生成させるとその分だけ条件が変わる。
    @Test("応答はテキストのみに限る")
    func textOnly() {
        let g = setup(GeminiLiveConfig())["generationConfig"] as? [String: Any]
        #expect(g?["responseModalities"] as? [String] == ["TEXT"])
    }

    /// **16kHz。** OpenAI 系（24kHz）と違う。取り込みから各々へ落とす。
    @Test("サンプルレートは 16kHz")
    func sampleRate() {
        #expect(GeminiLiveConfig.sampleRate == 16_000)
    }

    @Test("語彙ヒントを渡せる")
    func customVocabulary() {
        var c = GeminiLiveConfig()
        c.customVocabulary = ["kintone", "Garoon"]
        let t = setup(c)["inputAudioTranscription"] as? [String: Any]
        #expect(t?["customVocabulary"] as? [String] == ["kintone", "Garoon"])
    }

    /// 言語を指定しなければ自動判定に任せる。日英混在を見るときはこちら。
    @Test("言語未指定なら languageCodes を送らない")
    func omitsEmptyLanguages() {
        let t = setup(GeminiLiveConfig())["inputAudioTranscription"] as? [String: Any]
        #expect(t?["languageCodes"] == nil)
    }

    @Test("音声チャンクは base64 の PCM16")
    func audioPayload() {
        let data = GeminiLiveConfig.audioPayload(Data([1, 2, 3, 4]))
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let audio = (root?["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any]
        #expect(audio?["mimeType"] as? String == "audio/pcm;rate=16000")
        #expect(audio?["data"] as? String == Data([1, 2, 3, 4]).base64EncodedString())
    }
}
