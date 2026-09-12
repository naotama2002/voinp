import Foundation
import VoinpCore

/// 設定から**導出**される送信ポリシー。手で保守しない。
/// 設定のパースに失敗したら `.denyAll` を使う (fail closed)。
public struct EgressPolicySnapshot: Equatable, Sendable {
    public let masterAllow: Bool
    public let maxClass: EgressClass
    public let allowedHosts: Set<String>
    public let allowedPurposes: Set<EgressPurpose>
    /// 設定画面で「接続」を押した直後だけ入る、ただ 1 つの候補ホスト。
    public let probeCandidate: ProbeCandidate?

    public static let denyAll = EgressPolicySnapshot(
        masterAllow: false, maxClass: .loopback,
        allowedHosts: [], allowedPurposes: [], probeCandidate: nil)

    public init(masterAllow: Bool, maxClass: EgressClass, allowedHosts: Set<String>,
                allowedPurposes: Set<EgressPurpose>, probeCandidate: ProbeCandidate?) {
        self.masterAllow = masterAllow
        self.maxClass = maxClass
        self.allowedHosts = allowedHosts
        self.allowedPurposes = allowedPurposes
        self.probeCandidate = probeCandidate
    }

    /// 設定から導出する。ユーザーが埋めたフィールド以外から送信先は生えない。
    public static func derive(from settings: Settings, hasConfigError: Bool) -> EgressPolicySnapshot {
        guard !hasConfigError, settings.privacy.allowNetwork else { return .denyAll }

        var hosts = Set(settings.privacy.extraAllowlistHosts)
        if settings.refinement.enabled, settings.refinement.provider == "openai-compatible",
           let h = URL(string: settings.refinement.openaiCompatible.baseURL)?.host {
            hosts.insert(h)
        }
        let maxClass = settings.privacy.allowedEgressClasses
            .compactMap(EgressClass.init(name:)).max() ?? .loopback

        return EgressPolicySnapshot(
            masterAllow: true, maxClass: maxClass, allowedHosts: hosts,
            allowedPurposes: [.modelDiscovery, .refine], probeCandidate: nil)
    }
}

public enum EgressPurpose: String, Codable, Sendable {
    case modelDiscovery, refine, transcribe, updateCheck
}

/// ホスト許可リストだけを一時的に迂回する短命の候補。
/// マスタースイッチも egress クラス制限もプロキシ判定も素通りしない。
public struct ProbeCandidate: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let expiresAt: ContinuousClock.Instant

    public init(host: String, port: Int, expiresAt: ContinuousClock.Instant) {
        self.host = host; self.port = port; self.expiresAt = expiresAt
    }

    public func isValid(at now: ContinuousClock.Instant) -> Bool { now < expiresAt }
}

extension EgressClass {
    init?(name: String) {
        switch name {
        case "loopback": self = .loopback
        case "privateNetwork": self = .privateNetwork
        case "publicInternet": self = .publicInternet
        default: return nil
        }
    }
}
