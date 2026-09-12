import Foundation
import VoinpCore
import VoinpEngine

/// 合成ルート。`voinp` と `voinp-offline` の唯一の違いがここに入る。
///
/// `VoinpUIKit` はネットワーク側の型を知らない。実装は実行ターゲットが注入する。
public struct Dependencies: Sendable {
    public var llmClients: [any LLMClient]
    public var settings: Settings
    /// 音声認識の実装。差し替え可能にしてあるので、
    /// ダウンロード UI の確認などに別実装を挿せる。
    public var speechProvider: any TranscriptionProvider
    /// 設定が読めなかった理由。非 nil の間は通信を全拒否する（fail closed）。
    public var configError: String?

    public init(llmClients: [any LLMClient] = [],
                settings: Settings = Settings(),
                configError: String? = nil,
                speechProvider: (any TranscriptionProvider)? = nil) {
        self.llmClients = llmClients
        self.settings = settings
        self.configError = configError
        self.speechProvider = speechProvider ?? Dependencies.defaultSpeechProvider()
    }

    /// 環境変数で差し替えられるようにしておく（開発時の UI 確認用）。
    static func defaultSpeechProvider() -> any TranscriptionProvider {
        if ProcessInfo.processInfo.environment["VOINP_SIMULATE_DOWNLOAD"] != nil {
            return SimulatedDownloadProvider()
        }
        return AppleSpeechProvider()
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
