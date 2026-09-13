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

    /// このホスト・用途を許可するか。
    ///
    /// 許可ホストは設定から導出されたものだけ。
    /// 加えて、設定画面で「接続」を押した直後の短命な候補のみ通す
    /// （まだ保存されていないホストのモデル一覧を取るため）。
    public func allows(host: String, purpose: EgressPurpose,
                       at now: ContinuousClock.Instant) -> Bool {
        if allowedHosts.contains(host) { return true }
        if let candidate = probeCandidate,
           candidate.host == host,
           candidate.isValid(at: now),
           purpose == .modelDiscovery {
            return true
        }
        return false
    }

    /// 設定から導出する。ユーザーが埋めたフィールド以外から送信先は生えない。
    ///
    /// **強制に使うのは到達範囲 (`allowedEgressClasses`) だけ。**
    /// `openaiCompatible.operatorKind`（自社運用かどうか）は表示専用の申告であり、
    /// ここで参照してはいけない。申告で許可が広がると、
    /// 設定を書き換えられる攻撃者に送信経路を渡すことになる。
    public static func derive(from settings: Settings, hasConfigError: Bool) -> EgressPolicySnapshot {
        guard !hasConfigError, settings.privacy.allowNetwork else { return .denyAll }

        var hosts = Set(settings.privacy.extraAllowlistHosts)
        if settings.refinement.enabled, settings.refinement.provider == "openai-compatible",
           let h = URL(string: settings.refinement.openaiCompatible.baseURL)?.host {
            hosts.insert(h)
        }
        let maxClass = settings.privacy.allowedEgressClasses
            .compactMap(EgressClass.init(name:)).max() ?? .loopback

        // 設定画面で「接続」を押した直後だけ、未保存のホストを探索できるようにする。
        let candidate = ProbeAllowance.shared.current().map {
            ProbeCandidate(host: $0, port: 443, expiresAt: .now.advanced(by: .seconds(60)))
        }

        return EgressPolicySnapshot(
            masterAllow: true, maxClass: maxClass, allowedHosts: hosts,
            allowedPurposes: [.modelDiscovery, .refine], probeCandidate: candidate)
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

// MARK: - PrivacyPosture の導出

extension PrivacyPosture {
    /// 設定の純粋関数。I/O なし。完全にユニットテスト可能。
    ///
    /// `reachResolver` はホスト名を到達範囲に分類する。実運用では DNS 解決を伴うが、
    /// テストでは固定値を渡せるようにしてある（判定の分岐を漏れなく検査するため）。
    public static func evaluate(
        _ settings: Settings,
        hasConfigError: Bool,
        reachResolver: (String) -> EgressClass
    ) -> PrivacyPosture {
        if hasConfigError {
            return PrivacyPosture(level: .misconfigured, destinations: [])
        }
        guard settings.privacy.allowNetwork, settings.refinement.enabled,
              settings.refinement.provider == "openai-compatible",
              let url = URL(string: settings.refinement.openaiCompatible.baseURL),
              let host = url.host
        else {
            return .offline
        }

        let reach = reachResolver(host)
        // 到達範囲の上限を超える設定は、そもそもゲートが送らせない。
        let maxAllowed = settings.privacy.allowedEgressClasses
            .compactMap(EgressClass.init(name:)).max() ?? .loopback
        guard reach <= maxAllowed else { return .offline }

        let op: OperatorKind = switch settings.refinement.openaiCompatible.operatorKind {
        case "self-hosted": .selfHosted
        case "vendor": .vendor
        default: .unknown
        }

        let destination = Destination(
            dataKind: .refinedText,
            host: host,
            port: url.port ?? (url.scheme == "https" ? 443 : 80),
            reach: reach,
            operatorKind: op,
            providerID: "openai-compatible")

        // アイコンは到達範囲だけで決める。申告で優しくならない。
        let level: Level = switch reach {
        case .loopback: .loopbackOnly
        case .privateNetwork: .localNetwork
        case .publicInternet: .external
        }
        return PrivacyPosture(level: level, destinations: [destination])
    }
}
