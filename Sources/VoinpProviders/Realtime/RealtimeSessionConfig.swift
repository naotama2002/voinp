import Foundation
import VoinpCore

/// `session.update` に載せる設定。
///
/// 形はドキュメントと参考実装（kinopeee/interpreter-openai）に合わせてある。
/// **`noise_reduction` は `transcription` の中ではなく `audio.input` 直下**。
/// ここを間違えると設定全体が拒否される。
public struct RealtimeSessionConfig: Sendable, Equatable {
    /// OpenAI ではモデル名、Azure では**デプロイ名**。
    public var model: String
    /// 言語ヒント。複数渡せる。**macOS の `SpeechAnalyzer` には無い機能**で、
    /// 日英混在（「kintone の API で 401 が返る」）に効く。
    public var languages: [String]
    /// 認識バイアス。voinp の `termHints` がそのまま対応する。
    public var keywords: [String]
    public var prompt: String
    /// `minimal` / `low` / `medium` / `high` / `xhigh`。精度と遅延のつまみ。
    public var delay: String
    public var noiseReduction: String

    /// **24000 固定。** 実測でサーバーがこう言う:
    /// "PCM input rate must be 24000, or 16000 for MAI transcription."
    /// 16000 を指定すると `session.update` が拒否される。
    public static let sampleRate = PCM16FramePacketizer.sampleRate

    public init(model: String, languages: [String] = ["ja", "en"], keywords: [String] = [],
                prompt: String = "", delay: String = "low",
                noiseReduction: String = "near_field") {
        self.model = model
        self.languages = languages
        self.keywords = keywords
        self.prompt = prompt
        self.delay = delay
        self.noiseReduction = noiseReduction
    }

    /// 参考実装が実運用で踏んだ制約をここで吸収する。
    /// - `keywords` に `<` `>` が入ると **`session.update` 全体が拒否される**
    /// - `keywords` は 64 語まで
    /// - `prompt` は 1,000 文字まで
    public func payload() -> Data {
        let safeKeywords = keywords
            .filter { !$0.contains("<") && !$0.contains(">") && !$0.isEmpty }
            .prefix(64)
        let object: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Self.sampleRate],
                        "transcription": [
                            "model": model,
                            "languages": languages,
                            "delay": delay,
                            "prompt": String(prompt.prefix(1_000)),
                            "keywords": Array(safeKeywords),
                        ],
                        "noise_reduction": ["type": noiseReduction],
                        // VAD はサーバーに任せない。voinp はホットキーで区切るので、
                        // 勝手にターンを切られると確定のタイミングが読めなくなる。
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func appendAudio(_ frame: Data) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "type": "input_audio_buffer.append",
            "audio": frame.base64EncodedString(),
        ])) ?? Data()
    }

    static var commit: Data {
        (try? JSONSerialization.data(
            withJSONObject: ["type": "input_audio_buffer.commit"])) ?? Data()
    }
}
