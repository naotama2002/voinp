import Foundation

/// GPT-Live（`gpt-live-1`）のメッセージ。
///
/// **3 つ目のプロトコル。** Realtime とも Gemini とも違う。
///
/// | | Realtime | Gemini Live | GPT-Live |
/// |---|---|---|---|
/// | 設定 | `session.update` | `setup` | `session.start` |
/// | 音声 | `input_audio_buffer.append` | `realtimeInput.audio` | `session.input_audio.append` |
/// | 書き起こし | `...transcription.delta` | `interimInputTranscription` | `session.input_transcript.delta` |
/// | 差分の意味 | **追記** | **全文** | **追記** |
///
/// ## これは会話モデルであって文字起こし専用ではない
///
/// `gpt-live-1` は全二重の音声会話モデルで、`gpt-live-transcribe` の
/// ような文字起こし専用モデルではない。比較に入れるにあたって:
///
/// - **確定イベントが無い。** 公式に "doesn't emit an authoritative
///   turn-completed event" と書かれている。断片を自分で束ねるしかない
/// - 喋り返す（Output: Voice only）。`instructions` で抑えるが**保証はない**
/// - 課金は無音込みの実時間で、文字起こし専用モデルの約 3 倍
///
/// つまり**同条件での比較にはならない**。そのつもりで数字を読むこと。
public enum GPTLiveWireEvent: Sendable, Equatable {
    case sessionStarted
    /// ユーザーの発話の書き起こし。**追記分**。
    /// `output_transcript` はモデルの発話なので捨てる。
    case inputTranscriptDelta(String)
    case sessionClosed
    case error(String)
    case ignored

    public static func decode(_ data: Data) -> GPTLiveWireEvent {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String
        else { return .ignored }

        switch type {
        case "session.started":
            return .sessionStarted
        case "session.input_transcript.delta":
            return .inputTranscriptDelta(root["delta"] as? String ?? "")
        case "session.closed":
            return .sessionClosed
        case "error":
            let message = (root["error"] as? [String: Any])?["message"] as? String
                ?? root["message"] as? String ?? "詳細不明"
            return .error(message)
        default:
            // **`session.output_transcript.delta` はここで落ちる。**
            // モデルが喋った内容であって、比べたいユーザーの発話ではない。
            return .ignored
        }
    }
}

public struct GPTLiveConfig: Sendable, Equatable {
    public var model: String
    /// 喋り返さないよう頼む。**保証はない**（抑止する設定が文書化されていない）。
    public var instructions: String

    /// 24kHz。16kHz も受けると概要には書かれているが、
    /// Realtime 系と揃えておく。
    public static let sampleRate = 24_000

    public init(model: String = "gpt-live-1",
                instructions: String = "Transcribe only. Do not speak. Do not respond.") {
        self.model = model
        self.instructions = instructions
    }

    /// 接続直後に送る。Realtime の `session.update` とは別物で、
    /// **`session` は strict**（未知のフィールドを拒否する）。
    public func startPayload() -> Data {
        let object: [String: Any] = [
            "type": "session.start",
            "session": [
                "model": model,
                "instructions": instructions,
                // 自分のアプリで処理する（バックエンドへ委譲しない）。
                "delegation": ["type": "client"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func audioPayload(_ pcm16: Data) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "type": "session.input_audio.append",
            "audio": pcm16.base64EncodedString(),
        ])) ?? Data()
    }

    static var close: Data {
        (try? JSONSerialization.data(withJSONObject: ["type": "session.close"])) ?? Data()
    }
}
