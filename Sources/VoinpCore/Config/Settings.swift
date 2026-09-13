import Foundation

/// `~/Library/Application Support/voinp/config.json` の型。
/// 欠損キーは既定値で埋め、throw しない (部分的なエラーでディクテーションを止めない)。
public struct Settings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = Settings.currentSchemaVersion
    public var hotkey = Hotkey()
    public var audio = Audio()
    public var transcription = Transcription()
    public var refinement = Refinement()
    public var insertion = Insertion()
    public var privacy = Privacy()
    public var history = History()
    public var ui = UI()

    public init() {}


    public init(from decoder: any Decoder) throws {

        let c = try decoder.container(keyedBy: CodingKeys.self)

        let d = Settings()

        schemaVersion = c.value(.schemaVersion, d.schemaVersion)

        hotkey = c.value(.hotkey, d.hotkey)

        audio = c.value(.audio, d.audio)

        transcription = c.value(.transcription, d.transcription)

        refinement = c.value(.refinement, d.refinement)

        insertion = c.value(.insertion, d.insertion)

        privacy = c.value(.privacy, d.privacy)

        history = c.value(.history, d.history)

        ui = c.value(.ui, d.ui)

    }
    public struct Hotkey: Codable, Equatable, Sendable {
        public var binding = "ctrl+opt+space"
        public var behavior = "hybrid"        // hold | toggle | hybrid
        public var holdThresholdMs = 200
        public var cancelKey = "escape"
        public init() {}
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            binding = c.value(.binding, d.binding)
            behavior = c.value(.behavior, d.behavior)
            holdThresholdMs = c.value(.holdThresholdMs, d.holdThresholdMs)
            cancelKey = c.value(.cancelKey, d.cancelKey)
        }
    }

    public struct Audio: Codable, Equatable, Sendable {
        public var inputDeviceUID: String?
        public var playFeedbackSounds = true
        public var maxRecordingSeconds = 120
        public var minRecordingMs = 250
        public init() {}
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            inputDeviceUID = c.value(.inputDeviceUID, d.inputDeviceUID)
            playFeedbackSounds = c.value(.playFeedbackSounds, d.playFeedbackSounds)
            maxRecordingSeconds = c.value(.maxRecordingSeconds, d.maxRecordingSeconds)
            minRecordingMs = c.value(.minRecordingMs, d.minRecordingMs)
        }
    }

    public struct Transcription: Codable, Equatable, Sendable {
        public var provider = "apple.speechanalyzer"
        public var module = "dictation"       // dictation | transcription
        public var locale = "ja-JP"
        public var reserveLocales = ["ja-JP", "en-US"]
        public var modelRetention = "processLifetime"
        public var showPartialResults = true
        public var punctuation = "automatic"
        public var termHints: [String] = []
        public var termHintsFile: String?
        public init() {}
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            provider = c.value(.provider, d.provider)
            module = c.value(.module, d.module)
            locale = c.value(.locale, d.locale)
            reserveLocales = c.value(.reserveLocales, d.reserveLocales)
            modelRetention = c.value(.modelRetention, d.modelRetention)
            showPartialResults = c.value(.showPartialResults, d.showPartialResults)
            punctuation = c.value(.punctuation, d.punctuation)
            termHints = c.value(.termHints, d.termHints)
            termHintsFile = c.value(.termHintsFile, d.termHintsFile)
        }
    }

    public struct Refinement: Codable, Equatable, Sendable {
        public var enabled = false            // 既定オフ
        public var provider = "openai-compatible"
        /// 校正の追加指示。空なら共通ルールだけが適用される。
        /// プリセットを廃し、ユーザーが自分で書く方式にした。
        public var prompt = ""
        public var softDeadlineMs = 1500
        public var hardDeadlineMs = 4000
        public var maxRetries = 1
        public var disableAfterConsecutiveFailures = 3
        public var temperature = 0.1
        public var maxOutputTokens = 1024
        public var stripThinkTags = true
        public var openaiCompatible = OpenAICompatible()
        public init() {}
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            enabled = c.value(.enabled, d.enabled)
            provider = c.value(.provider, d.provider)
            prompt = c.value(.prompt, d.prompt)
            softDeadlineMs = c.value(.softDeadlineMs, d.softDeadlineMs)
            hardDeadlineMs = c.value(.hardDeadlineMs, d.hardDeadlineMs)
            maxRetries = c.value(.maxRetries, d.maxRetries)
            disableAfterConsecutiveFailures = c.value(.disableAfterConsecutiveFailures, d.disableAfterConsecutiveFailures)
            temperature = c.value(.temperature, d.temperature)
            maxOutputTokens = c.value(.maxOutputTokens, d.maxOutputTokens)
            stripThinkTags = c.value(.stripThinkTags, d.stripThinkTags)
            openaiCompatible = c.value(.openaiCompatible, d.openaiCompatible)
        }

        public struct OpenAICompatible: Codable, Equatable, Sendable {
            /// loopback / 社内 LAN / 社内 HTTPS サーバのいずれも取りうる。
            /// 例: "http://127.0.0.1:1234/v1", "https://llm.example.co.jp/v1"
            public var baseURL = "http://127.0.0.1:1234/v1"
            public var model = ""
            /// 誰が運用しているか。**表示専用の申告であり、送信許可を広げない。**
            /// 許可を決めるのは privacy.allowedEgressClasses（到達範囲）だけ。
            public var operatorKind = "self-hosted"   // "self-hosted" | "vendor"
            public var requiresAPIKey = false
            public var extraHeaders: [String: String] = [:]
            public init() {}
            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let d = Self()
                baseURL = c.value(.baseURL, d.baseURL)
                model = c.value(.model, d.model)
                operatorKind = c.value(.operatorKind, d.operatorKind)
                requiresAPIKey = c.value(.requiresAPIKey, d.requiresAPIKey)
                extraHeaders = c.value(.extraHeaders, d.extraHeaders)
            }
        }
    }

    public struct Insertion: Codable, Equatable, Sendable {
        public var strategy = "paste"         // paste | accessibility | keystroke | auto
        public var restoreClipboard = true
        public var pasteRestoreDelayMs = 250
        public var pasteKeyCode: Int?
        public var trailingSpace = false
        public init() {}
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            strategy = c.value(.strategy, d.strategy)
            restoreClipboard = c.value(.restoreClipboard, d.restoreClipboard)
            pasteRestoreDelayMs = c.value(.pasteRestoreDelayMs, d.pasteRestoreDelayMs)
            pasteKeyCode = c.value(.pasteKeyCode, d.pasteKeyCode)
            trailingSpace = c.value(.trailingSpace, d.trailingSpace)
        }
    }

    public struct Privacy: Codable, Equatable, Sendable {
        public var allowNetwork = false       // マスタースイッチ。既定オフ
        public var allowedEgressClasses = ["loopback"]
        public var extraAllowlistHosts: [String] = []
        public var auditLog = AuditLog()
        public var updateCheck = "never"      // never | manual。auto は存在しない
        public init() {}
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            allowNetwork = c.value(.allowNetwork, d.allowNetwork)
            allowedEgressClasses = c.value(.allowedEgressClasses, d.allowedEgressClasses)
            extraAllowlistHosts = c.value(.extraAllowlistHosts, d.extraAllowlistHosts)
            auditLog = c.value(.auditLog, d.auditLog)
            updateCheck = c.value(.updateCheck, d.updateCheck)
        }

        public struct AuditLog: Codable, Equatable, Sendable {
            public var enabled = true
            public var toDisk = true
            public var maxEntries = 500
            public init() {}
            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let d = Self()
                enabled = c.value(.enabled, d.enabled)
                toDisk = c.value(.toDisk, d.toDisk)
                maxEntries = c.value(.maxEntries, d.maxEntries)
            }
        }
    }

    public struct History: Codable, Equatable, Sendable {
        public var keepLastTranscripts = 0    // 既定 0 = 保存しない
        public init() {}
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            keepLastTranscripts = c.value(.keepLastTranscripts, d.keepLastTranscripts)
        }
    }

    public struct UI: Codable, Equatable, Sendable {
        public var showMenuBarPrivacyIndicator = true
        public var hudPosition = "bottomCenter"
        public var hudShowText = true         // false にすると認識テキストを HUD に出さない
        /// 認識結果と校正結果を上下に並べて表示する。
        /// 校正が何をしたのか（あるいは何もしなかったのか）を確認するための表示。
        public var hudShowComparison = false
        public init() {}
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            showMenuBarPrivacyIndicator = c.value(.showMenuBarPrivacyIndicator, d.showMenuBarPrivacyIndicator)
            hudPosition = c.value(.hudPosition, d.hudPosition)
            hudShowText = c.value(.hudShowText, d.hudShowText)
            hudShowComparison = c.value(.hudShowComparison, d.hudShowComparison)
        }
    }
}

extension Settings {
    /// 欠損キーを既定値で補う寛容なデコード。
    public static func decode(_ data: Data) throws -> Settings {
        let d = JSONDecoder()
        d.allowsJSON5 = true
        return try d.decode(Settings.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}

// MARK: - 寛容なデコード
//
// 既定値を書いただけでは足りない。Codable の合成 init は
// **キーが無いと throw する**ので、手で一部だけ書いた設定ファイルが
// 丸ごと読めなくなる（ユーザーに全項目を書かせるのは非現実的）。
// decodeIfPresent で埋める init(from:) を各構造体に用意する。

private extension KeyedDecodingContainer {
    /// 欠損・型違いのどちらでも既定値に倒す。
    /// 1 箇所の typo で設定全体が無効になるのを防ぐ。
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
    }
}
