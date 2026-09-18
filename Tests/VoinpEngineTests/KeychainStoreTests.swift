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

/// API キーの保存で壊してはいけないこと。
///
/// **マスクを入力欄に入れてはいけない。** `••••••` を text に流し込むと、
/// そのまま保存を押したときに**その文字列が鍵として保存される**。
/// 入力欄は常に空にして、状態は別の行で示す設計にしてある。
/// ここではその前提が崩れたときに困る挙動を固定する。
@Suite("API キーの保存で壊さないこと")
struct APIKeyStorageGuardTests {

    private func withTemporaryAccount(_ body: (CredentialRef) throws -> Void) rethrows {
        let ref = CredentialRef(account: "test/\(UUID().uuidString)")
        defer { try? KeychainStore().delete(ref) }
        try body(ref)
    }

    /// 空文字を保存すると、既存の鍵が使えない状態になる。
    /// UI 側は空のとき保存ボタンを無効にしているが、経路が増えたときのために固定する。
    @Test("空文字を保存すると鍵が壊れることを示す")
    func emptyValueBreaksTheKey() throws {
        try withTemporaryAccount { ref in
            let store = KeychainStore()
            try store.write("real-key", to: ref)
            #expect(store.exists(ref))

            try store.write("", to: ref)
            // EgressGate は空を「鍵なし」として扱い、ヘッダを付けない。
            let stored = try store.read(ref)
            #expect(stored?.isEmpty ?? true, "空になる＝認証が通らなくなる")
        }
    }

    /// 存在確認は値を返さない。**画面に値を出す経路を作らない。**
    @Test("存在確認では値を読み出さない")
    func existenceCheckDoesNotExposeValue() throws {
        try withTemporaryAccount { ref in
            let store = KeychainStore()
            #expect(!store.exists(ref), "未登録なら false")
            try store.write("secret", to: ref)
            #expect(store.exists(ref), "登録したら true")
        }
    }

    /// 口座はホスト単位。**接続先を変えたら別の鍵**になる。
    /// 状態表示も接続先に追随させないと、前のホストの鍵を見て
    /// 「設定済み」と誤解する。
    @Test("ホストが違えば別の口座")
    func keysAreHostScoped() throws {
        let a = CredentialRef.openAICompatible(host: "a.example.com")
        let b = CredentialRef.openAICompatible(host: "b.example.com")
        #expect(a != nil && b != nil)
        #expect(a != b)

        let store = KeychainStore()
        defer { try? store.delete(a!); try? store.delete(b!) }
        try store.write("key-for-a", to: a!)
        #expect(store.exists(a!))
        #expect(!store.exists(b!), "別ホストは未設定のまま")
    }
}
