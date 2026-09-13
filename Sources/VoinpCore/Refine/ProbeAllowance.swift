import Foundation

/// 保存前のホストへモデル探索だけを許す、短命の許可。
///
/// ホスト許可リストは設定から導出されるので、まだ保存していない URL は通らない。
/// ユーザーが「接続」を押した瞬間だけ、限定的に通す必要がある。
///
/// **限定は 4 つすべてを満たす。**
/// ホストは 1 つ / 用途はモデル探索のみ / 60 秒で失効 / 明示操作でのみ発行。
/// マスタースイッチと到達範囲の制限は通常どおり効く。
public final class ProbeAllowance: @unchecked Sendable {
    public static let shared = ProbeAllowance()

    private let lock = NSLock()
    private var host: String?
    private var expiresAt: ContinuousClock.Instant?

    public init() {}

    public func grant(host: String, duration: Duration = .seconds(60)) {
        lock.lock(); defer { lock.unlock() }
        self.host = host
        self.expiresAt = .now.advanced(by: duration)
    }

    public func revoke() {
        lock.lock(); defer { lock.unlock() }
        host = nil; expiresAt = nil
    }

    /// いま有効な候補。失効していれば nil。
    public func current(at now: ContinuousClock.Instant = .now) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let host, let expiresAt, now < expiresAt else { return nil }
        return host
    }
}
