import Foundation
import VoinpCore
import VoinpEngine

/// 合成ルート。`voinp` と `voinp-offline` の唯一の違いがここに入る。
///
/// `VoinpUIKit` はネットワーク側の型を知らない。実装は実行ターゲットが注入する。
public struct Dependencies: Sendable {
    /// 設定から LLM クライアントを組み立てる。
    ///
    /// **実体を持たない。** 起動時に作って抱えると、設定で接続先を変えても
    /// 古い URL のまま呼び続けることになる（実際にそうなっていた）。
    public var makeLLMClient: (@Sendable (Settings) -> (any LLMClient)?)?
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
    /// 設定からクラウド音声認識を組み立てる。
    ///
    /// **オフライン版では nil。** そのときクラウドは選べず、選ばれていても
    /// 必ずローカルに倒れる。`speechProvider` と同じく実体を持たないのは、
    /// 接続先やモデルを変えたときに古い設定のまま使い続けないため。
    public var makeCloudSpeechProvider: (@Sendable (Settings) -> (any TranscriptionProvider)?)?
    /// 設定が読めなかった理由。非 nil の間は通信を全拒否する（fail closed）。
    public var configError: String?

    public init(makeLLMClient: (@Sendable (Settings) -> (any LLMClient)?)? = nil,
                settings: Settings = Settings(),
                configError: String? = nil,
                speechProvider: (any TranscriptionProvider)? = nil,
                credentials: (any CredentialStore)? = nil,
                discoverModels: (@Sendable (String) async -> ModelDiscoveryResult)? = nil,
                makeCloudSpeechProvider:
                    (@Sendable (Settings) -> (any TranscriptionProvider)?)? = nil) {
        self.makeLLMClient = makeLLMClient
        self.settings = settings
        self.configError = configError
        self.speechProvider = speechProvider ?? Dependencies.defaultSpeechProvider()
        self.credentials = credentials
        self.discoverModels = discoverModels
        self.makeCloudSpeechProvider = makeCloudSpeechProvider
    }

    /// クラウド認識を UI に出すか。オフライン版では常に false。
    public var supportsCloudTranscription: Bool { makeCloudSpeechProvider != nil }

    /// 環境変数で差し替えられるようにしておく（開発時の UI 確認用）。
    static func defaultSpeechProvider() -> any TranscriptionProvider {
        if ProcessInfo.processInfo.environment["VOINP_SIMULATE_DOWNLOAD"] != nil {
            return SimulatedDownloadProvider()
        }
        return AppleSpeechProvider()
    }

    /// ネットワークを含まない共通部分。
    public static func base() -> Dependencies { Dependencies() }

    public func withLLM(_ make: @escaping @Sendable (Settings) -> (any LLMClient)?) -> Dependencies {
        var copy = self
        copy.makeLLMClient = make
        return copy
    }

    /// 校正機能を UI に出すか。オフライン版では常に false。
    public var supportsRefinement: Bool { makeLLMClient != nil }
}

/// モデル探索の結果。エラーは表示用の文字列で受ける
/// （UI 層がネットワーク層のエラー型を知る必要はない）。
public enum ModelDiscoveryResult: Sendable {
    /// **探索で実際に通った URL をそのまま返す。**
    ///
    /// かつてはモデル一覧だけを返し、UI 側が入力文字列に `/v1` を付け直して
    /// 保存していた。探索は複数の候補を試すので、`https://host/custom` で
    /// 疎通できても保存されるのは `https://host/custom/v1` になり、
    /// **接続テストは成功するのに校正だけ失敗する**という分かりにくい状態になった。
    /// 確定した URL を持ち回れば、テストした対象と保存する対象が必ず一致する。
    case success(baseURL: String, models: [ModelInfo])
    case failure(String)
}
