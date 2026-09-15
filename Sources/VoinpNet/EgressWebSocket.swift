import Foundation
import Synchronization
import VoinpCore

/// 双方向ストリーム 1 本。**`EgressGate.connect` を通らないと生成できない。**
///
/// 音声をクラウドの認識エンジンへ流すために足した。リクエスト／レスポンス 1 往復の
/// `send()` とは寿命も失敗の形も違うが、**送信前の判定は完全に同じ経路を通る**
/// （`EgressGate.authorize`）。
public protocol EgressWebSocketChannel: Sendable, AnyObject {
    /// テキストフレームとして送る。JSON を想定している。
    func send(_ json: Data) async throws
    /// 1 メッセージ受け取る。`close()` されると投げて解ける。
    func receive() async throws -> Data
    /// 何度呼んでも安全。`receive()` の待ちを解く責任を持つ。
    func close() async
    /// これまでに送受信したアプリケーションペイロードのバイト数。
    /// フレーミングと TLS の上乗せは含まない。**ゲート側が数える**
    /// （呼び出し側の自己申告にしない）。
    var bytes: (out: Int, in: Int) { get }
}

/// `URLSessionWebSocketTask` の薄いラッパ。
///
/// **`URLSessionWebSocketTask.receive()` は Swift の Task キャンセルを見ない。**
/// タイムアウトさせたい側は `close()` を呼んで解く必要がある。
/// 参考実装（kinopeee/interpreter-openai）が実測でこの注意を残しており、
/// こちらでも同じ前提で組んである。
final class URLSessionWebSocketChannel: EgressWebSocketChannel, @unchecked Sendable {
    private struct Counters { var out = 0; var `in` = 0; var closed = false }

    private let task: URLSessionWebSocketTask
    /// `Mutex` を使う。`NSLock` は async 文脈から呼べない（Swift 6 で診断される）。
    private let counters = Mutex(Counters())

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    var bytes: (out: Int, in: Int) {
        counters.withLock { ($0.out, $0.in) }
    }

    func send(_ json: Data) async throws {
        try await task.send(.data(json))
        counters.withLock { $0.out += json.count }
    }

    func receive() async throws -> Data {
        let message = try await task.receive()
        let data: Data = switch message {
        case .data(let d): d
        case .string(let s): Data(s.utf8)
        @unknown default: Data()
        }
        counters.withLock { $0.in += data.count }
        return data
    }

    func close() async {
        let alreadyClosed = counters.withLock { c -> Bool in
            let was = c.closed
            c.closed = true
            return was
        }
        guard !alreadyClosed else { return }
        // **closeReason は渡さない。** 受け取る側も読まない（EgressStreamCloseCode 参照）。
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// WebSocket の終了理由。**監査ログにはこの数値だけを載せる。**
///
/// サーバーが返す `closeReason: Data?` は**読まない・記録しない・ログしない**。
/// あれは相手が任意のテキストを入れられるフィールドで、
/// 「監査ログに本文を入れない」という不変条件を壊す唯一の穴になる。
public enum EgressStreamCloseCode: Int, Sendable, Equatable {
    case normal = 1000
    case abnormal = 1006
    case policyRevoked = 4001
    case handshakeFailed = 4002
    case transportFailed = 4003
}

/// 監査の締めを保証するための包み。
///
/// `close()` が呼ばれたときに**必ず 1 度だけ** `streamClosed` を記録する。
/// 呼び出し側が記録し忘れる余地を残さない。
final class AuditedWebSocketChannel: EgressWebSocketChannel, @unchecked Sendable {
    private let inner: any EgressWebSocketChannel
    private let host: String
    private let purpose: EgressPurpose
    private let reach: EgressClass
    private let openedAt: ContinuousClock.Instant
    private let audit: EgressAuditLog
    private let recorded = Mutex(false)

    init(inner: any EgressWebSocketChannel, host: String, purpose: EgressPurpose,
         reach: EgressClass, openedAt: ContinuousClock.Instant, audit: EgressAuditLog) {
        self.inner = inner
        self.host = host
        self.purpose = purpose
        self.reach = reach
        self.openedAt = openedAt
        self.audit = audit
    }

    var bytes: (out: Int, in: Int) { inner.bytes }

    func send(_ json: Data) async throws { try await inner.send(json) }
    func receive() async throws -> Data { try await inner.receive() }

    func close() async {
        await inner.close()
        let alreadyRecorded = recorded.withLock { done -> Bool in
            let was = done
            done = true
            return was
        }
        guard !alreadyRecorded else { return }
        let counted = inner.bytes
        await audit.record(.streamClosed(host: host, purpose: purpose, reach: reach,
                                         code: .normal,
                                         bytesOut: counted.out, bytesIn: counted.in,
                                         duration: ContinuousClock.now - openedAt))
    }
}
