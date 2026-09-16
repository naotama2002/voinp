import Foundation
import Testing
import VoinpCore
@testable import VoinpEngine

/// 資格情報の保管が実際に動くこと。
///
/// **実機で「API キーを保存できません (-34018)」を踏んだ箇所。**
/// `kSecUseDataProtectionKeychain` を指定していたため、サンドボックス外の
/// このアプリでは `keychain-access-groups` の entitlement を要求されて失敗していた。
@Suite("Keychain への保管")
struct KeychainStoreTests {

    /// テストで汚さないよう、専用の口座名を使って必ず消す。
    private func withTemporaryAccount(_ body: (CredentialRef) throws -> Void) rethrows {
        let ref = CredentialRef(account: "test/\(UUID().uuidString)")
        defer { try? KeychainStore().delete(ref) }
        try body(ref)
    }

    /// **これが落ちていた。** 書けなければ API キーを設定画面から入れられない。
    @Test("書いて読める")
    func roundTrip() throws {
        try withTemporaryAccount { ref in
            let store = KeychainStore()
            try store.write("s3cret-value", to: ref)
            #expect(try store.read(ref) == "s3cret-value")
        }
    }

    @Test("上書きできる")
    func overwrite() throws {
        try withTemporaryAccount { ref in
            let store = KeychainStore()
            try store.write("first", to: ref)
            try store.write("second", to: ref)
            #expect(try store.read(ref) == "second")
        }
    }

    @Test("消したら読めない")
    func deleteRemoves() throws {
        try withTemporaryAccount { ref in
            let store = KeychainStore()
            try store.write("x", to: ref)
            try store.delete(ref)
            #expect(try store.read(ref) == nil)
        }
    }

    /// 未登録のホストへ前のサーバーの鍵が飛ばないこと。
    @Test("登録していない口座は nil")
    func unknownAccountIsNil() throws {
        #expect(try KeychainStore().read(
            CredentialRef(account: "test/never-written-\(UUID().uuidString)")) == nil)
    }
}
