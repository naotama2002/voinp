import Foundation
import VoinpCore

/// 合成ルート。`voinp` と `voinp-offline` の唯一の違いがここに入る。
///
/// `VoinpUIKit` はネットワーク側の型を知らない。実装は実行ターゲットが注入する。
public struct Dependencies: Sendable {
    public var llmClients: [any LLMClient]
    public var settings: Settings

    public init(llmClients: [any LLMClient] = [], settings: Settings = Settings()) {
        self.llmClients = llmClients
        self.settings = settings
    }

    /// ネットワークを含まない共通部分。
    public static func base() -> Dependencies { Dependencies() }

    public func withLLM(_ clients: [any LLMClient]) -> Dependencies {
        var copy = self
        copy.llmClients = clients
        return copy
    }

    /// 校正機能を UI に出すか。オフライン版では常に false。
    public var supportsRefinement: Bool { !llmClients.isEmpty }
}
