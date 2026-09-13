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
    /// API キーの保管。オフライン版でも設定 UI で使うので常に持つ。
    public var credentials: (any CredentialStore)?
    /// モデル一覧を取りに行く手段。
    ///
    /// **`EgressGate` を直接持たない。** 持つと `VoinpUIKit` が `VoinpNet` に
    /// 依存することになり、オフライン版がビルドできなくなる
    /// （実際に壊れて気づいた）。合成ルートが closure で注入する。
    public var discoverModels: (@Sendable (String) async -> ModelDiscoveryResult)?
    /// 設定が読めなかった理由。非 nil の間は通信を全拒否する（fail closed）。
    public var configError: String?

    public init(llmClients: [any LLMClient] = [],
                settings: Settings = Settings(),
                configError: String? = nil,
                speechProvider: (any TranscriptionProvider)? = nil,
                credentials: (any CredentialStore)? = nil,
                discoverModels: (@Sendable (String) async -> ModelDiscoveryResult)? = nil) {
        self.llmClients = llmClients
        self.settings = settings
        self.configError = configError
        self.speechProvider = speechProvider ?? Dependencies.defaultSpeechProvider()
        self.credentials = credentials
        self.discoverModels = discoverModels
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

/// モデル探索の結果。エラーは表示用の文字列で受ける
/// （UI 層がネットワーク層のエラー型を知る必要はない）。
public enum ModelDiscoveryResult: Sendable {
    case success([ModelInfo])
    case failure(String)
}
