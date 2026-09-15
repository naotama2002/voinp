import Foundation

/// サーバーから届く JSON を解釈したもの。**ネットワークを知らない。**
/// I/O ゼロなので、実エンドポイントなしで全分岐をテストできる。
public enum RealtimeWireEvent: Sendable, Equatable {
    /// 接続直後。この後に `session.update` を送る。
    case sessionCreated
    /// 設定が受理された。**ここから音声を送ってよい。**
    case sessionUpdated
    /// 書き起こしの**追記分**。全文ではない。
    case transcriptDelta(itemID: String, delta: String)
    /// 1 ターンの確定。`transcript` は**全文**。
    case transcriptCompleted(itemID: String, transcript: String)
    case transcriptFailed(itemID: String)
    case serverError(RealtimeServerError)
    /// 扱わないもの。型だけ残して落とす。
    case ignored(String)

    public static func decode(_ data: Data) -> RealtimeWireEvent {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return .ignored("") }

        func itemID() -> String { object["item_id"] as? String ?? "" }

        switch type {
        case "session.created", "transcription_session.created":
            return .sessionCreated
        case "session.updated", "transcription_session.updated":
            return .sessionUpdated
        case "conversation.item.input_audio_transcription.delta":
            return .transcriptDelta(itemID: itemID(), delta: object["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .transcriptCompleted(itemID: itemID(),
                                        transcript: object["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.failed":
            return .transcriptFailed(itemID: itemID())
        case "error":
            return .serverError(RealtimeServerError(object["error"] as? [String: Any] ?? [:]))
        default:
            return .ignored(type)
        }
    }
}

public struct RealtimeServerError: Sendable, Equatable {
    public let type: String?
    public let code: String?
    public let message: String

    init(_ object: [String: Any]) {
        type = object["type"] as? String
        code = object["code"] as? String
        message = object["message"] as? String ?? "詳細不明"
    }

    public init(type: String?, code: String?, message: String) {
        self.type = type; self.code = code; self.message = message
    }

    /// 接続を畳むべきか。
    ///
    /// **知らないコードは致命として扱う。** 送り続けて黙って劣化するより、
    /// 退避して macOS のエンジンに切り替えるほうが被害が小さい。
    public var isFatal: Bool {
        switch code {
        case "input_audio_buffer_commit_empty": false   // 無音で commit しただけ
        default: true
        }
    }
}
