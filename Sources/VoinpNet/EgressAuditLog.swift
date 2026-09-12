import Foundation
import VoinpCore

/// 送信の記録。
///
/// **ユーザーの内容を保持できるフィールドを意図的に持たない。**
/// 型にテキストを入れる場所が無ければ、不注意な記録が漏洩にならない。
/// URL のクエリ文字列もヘッダも本文も記録しない。
public struct EgressRecord: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case allowed(status: Int)
        case denied(EgressDenialReason)
        case failed(errorCode: Int)
    }

    public let timestamp: Date
    public let host: String
    public let purpose: EgressPurpose
    public let reach: EgressClass?
    public let bytesOut: Int
    public let bytesIn: Int
    public let durationMs: Int
    public let outcome: Outcome

    static func allowed(host: String, purpose: EgressPurpose, status: Int,
                        reach: EgressClass, bytesOut: Int, bytesIn: Int,
                        duration: Duration) -> EgressRecord {
        EgressRecord(timestamp: Date(), host: host, purpose: purpose, reach: reach,
                     bytesOut: bytesOut, bytesIn: bytesIn,
                     durationMs: Int(duration.components.seconds * 1000
                                     + duration.components.attoseconds / 1_000_000_000_000_000),
                     outcome: .allowed(status: status))
    }

    static func denied(host: String, purpose: EgressPurpose,
                       reason: EgressDenialReason) -> EgressRecord {
        EgressRecord(timestamp: Date(), host: host, purpose: purpose, reach: nil,
                     bytesOut: 0, bytesIn: 0, durationMs: 0, outcome: .denied(reason))
    }

    static func failed(host: String, purpose: EgressPurpose, reason: Int) -> EgressRecord {
        EgressRecord(timestamp: Date(), host: host, purpose: purpose, reach: nil,
                     bytesOut: 0, bytesIn: 0, durationMs: 0, outcome: .failed(errorCode: reason))
    }
}

/// 直近の送信を保持する。既定では メモリ上のみ。
public actor EgressAuditLog {
    private var records: [EgressRecord] = []
    private let limit: Int

    public init(limit: Int = 500) { self.limit = limit }

    func record(_ r: EgressRecord) {
        records.append(r)
        if records.count > limit { records.removeFirst(records.count - limit) }
        Log.net.info("""
            egress \(r.host, privacy: .public) \(r.purpose.rawValue, privacy: .public) \
            \(String(describing: r.outcome), privacy: .public) \
            out=\(r.bytesOut, privacy: .public) in=\(r.bytesIn, privacy: .public)
            """)
    }

    public var recent: [EgressRecord] { records }

    public func clear() { records.removeAll() }
}
