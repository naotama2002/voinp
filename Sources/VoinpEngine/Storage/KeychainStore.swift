import Foundation
import Security
import VoinpCore

/// API キーの保管。**設定ファイルには絶対に書かない。**
///
/// - 1 サービス + アカウント名で管理する（全消しが 1 回の呼び出しで済み、
///   Keychain Access.app で一覧が読める）
/// - `ThisDeviceOnly` にして iCloud Keychain に同期させない。
///   「この Mac から出ない」を謳うアプリが資格情報を同期させるのは自己矛盾。
public struct KeychainStore: CredentialStore {

    public init() {}

    public func read(_ ref: CredentialRef) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialRef.service,
            kSecAttrAccount as String: ref.account,
            kSecUseDataProtectionKeychain as String: true,
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
            kSecUseDataProtectionKeychain as String: true,
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
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 保存されているか。値そのものは返さない。
    public func exists(_ ref: CredentialRef) -> Bool {
        (try? read(ref)) .flatMap { $0 } != nil
    }
}
