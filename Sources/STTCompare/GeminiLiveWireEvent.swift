import Foundation

/// Gemini Live API のメッセージ。**OpenAI 系とは別物。**
///
/// | | OpenAI Realtime | Gemini Live |
/// |---|---|---|
/// | 設定 | `session.update` | `setup` |
/// | 音声 | `input_audio_buffer.append` | `realtimeInput.audio` |
/// | 暫定 | `...transcription.delta`（**追記**） | `interimInputTranscription`（**全文**） |
/// | 確定 | `...transcription.completed` | `inputTranscription` |
///
/// **暫定の意味が逆。** OpenAI は追記分、Gemini は毎回その時点の全文。
/// voinp の `.partial` は「丸ごと置換」なので、**Gemini はそのまま流せる**。
/// OpenAI 側は累積が要る（`RealtimeTranscriptAssembler`）。ここを取り違えると
/// 片方は断片しか出ず、もう片方は同じ文字が二重に並ぶ。
public enum GeminiLiveWireEvent: Sendable, Equatable {
    /// 設定が受理された。ここから音声を送ってよい。
    case setupComplete
    /// 暫定。**その時点の全文**であって追記分ではない。
    case interimTranscript(String)
    /// 確定。
    case finalTranscript(String)
    /// ターンが終わった。
    case turnComplete
    case error(String)
    case ignored

    public static func decode(_ data: Data) -> GeminiLiveWireEvent {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .ignored }

        if root["setupComplete"] != nil { return .setupComplete }

        if let error = root["error"] as? [String: Any] {
            return .error(error["message"] as? String ?? "詳細不明")
        }

        guard let content = root["serverContent"] as? [String: Any] else { return .ignored }

        // 確定を先に見る。同じメッセージに両方入っている場合、確定を採る。
        if let final = (content["inputTranscription"] as? [String: Any])?["text"] as? String,
           !final.isEmpty {
            return .finalTranscript(final)
        }
        if let interim = (content["interimInputTranscription"] as? [String: Any])?["text"]
            as? String {
            return .interimTranscript(interim)
        }
        if content["turnComplete"] as? Bool == true { return .turnComplete }
        return .ignored
    }
}

/// `setup` に載せる設定。
public struct GeminiLiveConfig: Sendable, Equatable {
    public var model: String
    /// 語彙ヒント。voinp の `termHints` がそのまま対応する
    /// （OpenAI の `keywords` と同じ位置づけ）。
    public var customVocabulary: [String]
    /// 空にすると自動判定。日英混在を見るときは空のほうが素直。
    public var languageCodes: [String]
    public var mode: String

    /// **16kHz 固定。** OpenAI 系（24kHz）と違うので、
    /// 取り込みから各々へダウンサンプルする。
    public static let sampleRate = 16_000

    public init(model: String = "models/gemini-3.5-transcribe-live",
                customVocabulary: [String] = [],
                languageCodes: [String] = [],
                mode: String = "SMART") {
        self.model = model
        self.customVocabulary = customVocabulary
        self.languageCodes = languageCodes
        self.mode = mode
    }

    /// 接続直後に送る設定。
    ///
    /// **`responseModalities` を TEXT にする。** 音声で返してこさせない。
    /// 比較したいのは文字起こしであって応答ではないし、
    /// 音声を生成させるとその分だけ条件が変わる。
    public func setupPayload() -> Data {
        var transcription: [String: Any] = ["mode": mode]
        if !languageCodes.isEmpty { transcription["languageCodes"] = languageCodes }
        if !customVocabulary.isEmpty {
            transcription["customVocabulary"] = Array(customVocabulary.prefix(64))
        }
        let object: [String: Any] = [
            "setup": [
                "model": model,
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// 音声チャンク。base64 の PCM16。
    static func audioPayload(_ pcm16: Data) -> Data {
        let object: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=\(sampleRate)",
                    "data": pcm16.base64EncodedString(),
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// 送信終了。
    static var audioStreamEnd: Data {
        (try? JSONSerialization.data(
            withJSONObject: ["realtimeInput": ["audioStreamEnd": true]])) ?? Data()
    }
}
