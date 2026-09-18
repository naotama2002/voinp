import Foundation
import VoinpCore
import VoinpEngine

/// 鍵の置き場所を両方見る。**値のまま持たず、口座名で参照する。**
///
/// 比較ツールは鍵を 2 箇所から拾う:
/// - 環境変数（比較専用に一時的な鍵を使いたいとき）
/// - voinp の Keychain（本体でクラウド認識を設定済みなら、そのまま使える）
///
/// ## 片方しか見ない実装で実際に踏んだ
///
/// エンジンの組み立ては Keychain の口座を指していたのに、
/// `EgressGate` には**環境変数しか読まないストア**を渡していた。
/// 鍵が解決できず、ヘッダが付かないまま接続し、
/// ハンドシェイクが `-1011`（`NSURLErrorBadServerResponse`）で失敗していた。
///
/// エラーが「サーバーの応答が不正」としか言わないので、
/// URL・モデル名・認証方式を順に疑うことになり、原因の特定に時間がかかった。
/// **鍵の解決経路は 1 本にまとめること。**
public struct CompareCredentials: CredentialStore {
    private let keychain = KeychainStore()

    public init() {}

    public func read(_ ref: CredentialRef) throws -> String? {
        // 口座名が環境変数名なら環境変数。そうでなければ Keychain。
        if let fromEnvironment = ProcessInfo.processInfo.environment[ref.account],
           !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return try keychain.read(ref)
    }

    /// 比較ツールは鍵を書かない。読むだけ。
    public func write(_ value: String, to ref: CredentialRef) throws {}
    public func delete(_ ref: CredentialRef) throws {}
}
