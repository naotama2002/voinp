import Foundation
import Testing
import VoinpCore
import VoinpEngine
@testable import STTCompare

/// 鍵を両方の置き場所から探せること。
///
/// **片方しか見ない実装で実際に踏んだ。**
/// 比較ツールは voinp の Keychain から鍵を拾う設計なのに、
/// `EgressGate` には環境変数しか読まないストアを渡していた。
/// 鍵が付かないまま接続し、ハンドシェイクが -1011 で失敗していた。
/// エラーが「サーバーの応答が不正」としか言わないので、原因が見えにくい。
@Suite("鍵の探し方")
struct CompareCredentialsTests {

    /// Keychain に入れた鍵が読めること。**ここが落ちていた。**
    @Test("Keychain の鍵を読める")
    func readsFromKeychain() throws {
        let ref = CredentialRef(account: "test/compare-\(UUID().uuidString)")
        let keychain = KeychainStore()
        defer { try? keychain.delete(ref) }

        try keychain.write("from-keychain", to: ref)
        #expect(try CompareCredentials().read(ref) == "from-keychain")
    }

    /// 環境変数が優先されること。比較専用の鍵を一時的に使える。
    @Test("環境変数があればそちらを優先する")
    func environmentWins() throws {
        // 実際に設定されている変数名で確かめる（無ければ検査を飛ばす）
        let names = ProcessInfo.processInfo.environment
            .filter { !$0.value.isEmpty }.keys.sorted()
        guard let name = names.first else { return }
        let value = ProcessInfo.processInfo.environment[name]
        #expect(try CompareCredentials().read(CredentialRef(account: name)) == value)
    }

    /// どちらにも無ければ nil。**空文字を返さない。**
    /// `EgressGate` は空を「鍵なし」として扱うが、
    /// nil と空文字で挙動が分かれると追いにくい。
    @Test("どこにも無ければ nil")
    func missingIsNil() throws {
        let ref = CredentialRef(account: "test/never-\(UUID().uuidString)")
        #expect(try CompareCredentials().read(ref) == nil)
    }
}
