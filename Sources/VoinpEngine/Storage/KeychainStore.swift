import Foundation
import Security
import VoinpCore

/// API キーの保管。**設定ファイルには絶対に書かない。**
///
/// - 1 サービス + アカウント名で管理する（全消しが 1 回の呼び出しで済み、
///   Keychain Access.app で一覧が読める）
/// - `ThisDeviceOnly` にして iCloud Keychain に同期させない。
///   「この Mac から出ない」を謳うアプリが資格情報を同期させるのは自己矛盾。
///
/// ## `kSecUseDataProtectionKeychain` を使わない
///
/// 指定すると **`errSecMissingEntitlement (-34018)` で保存に失敗する**。
/// データ保護キーチェーンは、サンドボックス外のアプリでは
/// `keychain-access-groups` の entitlement を要求し、それには
/// provisioning profile が要る。このアプリはサンドボックスを使えず
/// （AX と CGEvent が拒否されるため。docs/07 参照）、
/// 各自が自分の証明書で署名する配布方式なので profile を前提にできない。
///
/// ファイルベースの従来のキーチェーンを使う。`ThisDeviceOnly` と
/// `kSecAttrSynchronizable = false` は変わらず効くので、
/// iCloud へ同期しない性質は保たれる。
///
/// **実機で踏んだ**: 設定画面から API キーを保存しようとして
/// 「API キーを保存できません (-34018)」がログに出ていた。
public struct KeychainStore: CredentialStore {

    public init() {}

    public func read(_ ref: CredentialRef) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialRef.service,
            kSecAttrAccount as String: ref.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, to ref: CredentialRef) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialRef.service,
            kSecAttrAccount as String: ref.account,
        ]
        SecItemDelete(base as CFDictionary)

        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VoinpError.configUnreadable("API キーを保存できません (\(status))")
        }
    }

    public func delete(_ ref: CredentialRef) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialRef.service,
            kSecAttrAccount as String: ref.account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 保存されているか。値そのものは返さない。
    public func exists(_ ref: CredentialRef) -> Bool {
        (try? read(ref)) .flatMap { $0 } != nil
    }
}
