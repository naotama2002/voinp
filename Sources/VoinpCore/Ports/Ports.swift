import Foundation

/// 校正 LLM のトランスポート。OpenAI 互換 / Anthropic / Gemini / FoundationModels がここに嵌まる。
public protocol LLMClient: Sendable {
    var identifier: String { get }
    func listModels() async throws -> [ModelInfo]
    func complete(_ request: CompletionRequest) async throws -> CompletionResult
}

public struct ModelInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let contextWindow: Int?
    public init(id: String, displayName: String, contextWindow: Int? = nil) {
        self.id = id; self.displayName = displayName; self.contextWindow = contextWindow
    }
}

/// 校正タスクは常に system 1 ターン + user 1 ターン。
/// 型を絞ることで「画面の内容も文脈に入れる」等の拡張を構造的に防いでいる。
public struct CompletionRequest: Sendable {
    public var model: String
    public var system: String
    public var user: String
    public var temperature: Double?
    public var maxOutputTokens: Int?
    public var stop: [String]
    public var timeout: Duration
    public init(model: String, system: String, user: String, temperature: Double? = nil,
                maxOutputTokens: Int? = nil, stop: [String] = [], timeout: Duration = .seconds(4)) {
        self.model = model; self.system = system; self.user = user
        self.temperature = temperature; self.maxOutputTokens = maxOutputTokens
        self.stop = stop; self.timeout = timeout
    }
}

public struct CompletionResult: Sendable {
    public let text: String
    public let latency: Duration
    public init(text: String, latency: Duration) { self.text = text; self.latency = latency }
}

/// テキスト挿入戦略。
public protocol TextInserter: Sendable {
    var identifier: String { get }
    func insert(_ text: String, into target: InsertionTarget) async throws
}

/// 資格情報。本体は常に Keychain にあり、設定ファイルには現れない。
public struct CredentialRef: Hashable, Codable, Sendable {
    public static let service = "com.naotama2002.voinp"
    public let account: String
    public init(account: String) { self.account = account }
}

public protocol CredentialStore: Sendable {
    func read(_ ref: CredentialRef) throws -> String?
    func write(_ value: String, to ref: CredentialRef) throws
    func delete(_ ref: CredentialRef) throws
}
