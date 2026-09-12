import Foundation
import VoinpCore

/// ホストを到達範囲に分類する。
///
/// **ホスト名の文字列ではなく、解決後のアドレスで判定する。**
/// `http://my-llm.local` のようにローカルに見えても、実際は外に出ることがある。
public struct HostClassifier: Sendable {

    public init() {}

    /// 解決して分類する。**返ったアドレスすべてが条件を満たすことを要求する。**
    /// 片方が 127.0.0.1、もう片方が公開 IP というホストを loopback 扱いしない。
    public func classify(host: String) async throws -> EgressClass {
        // リテラル IP はそのまま分類できる（DNS も引かないので真にゼロ egress）。
        if let literal = Self.classifyLiteral(host) { return literal }

        let addresses = try await Self.resolve(host)
        guard !addresses.isEmpty else { throw VoinpError.egressDenied(.hostNotAllowed(host)) }

        // 最も遠いものに合わせる。
        return addresses.map(Self.classifyAddress).max() ?? .publicInternet
    }

    /// 文字列が IP リテラルならその場で分類する。
    static func classifyLiteral(_ host: String) -> EgressClass? {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard h.contains(where: { $0.isNumber }) || h.contains(":") else { return nil }
        guard isIPLiteral(h) else { return nil }
        return classifyAddress(h)
    }

    static func isIPLiteral(_ s: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    /// アドレス文字列を到達範囲に分類する。
    static func classifyAddress(_ address: String) -> EgressClass {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let a = UInt32(bigEndian: v4.s_addr)
            let (b1, b2) = (UInt8(a >> 24), UInt8((a >> 16) & 0xFF))
            if b1 == 127 { return .loopback }                                  // 127.0.0.0/8
            if b1 == 10 { return .privateNetwork }                             // 10.0.0.0/8
            if b1 == 192 && b2 == 168 { return .privateNetwork }               // 192.168.0.0/16
            if b1 == 172 && (16...31).contains(b2) { return .privateNetwork }  // 172.16.0.0/12
            if b1 == 169 && b2 == 254 { return .privateNetwork }               // link-local
            return .publicInternet
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes == Array(repeating: 0, count: 15) + [1] { return .loopback }  // ::1
            if bytes[0] & 0xFE == 0xFC { return .privateNetwork }                  // fc00::/7
            if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return .privateNetwork }  // fe80::/10
            return .publicInternet
        }
        return .publicInternet
    }

    /// DNS 解決。**これ自体がホスト名を DNS サーバに漏らす**ので、
    /// リテラル IP の loopback だけが真にゼロ egress である（docs/06-privacy.md）。
    static func resolve(_ host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC,
                                     ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else {
                    cont.resume(throwing: VoinpError.egressDenied(.hostNotAllowed(host)))
                    return
                }
                defer { freeaddrinfo(head) }

                var out: [String] = []
                var node: UnsafeMutablePointer<addrinfo>? = head
                while let n = node {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(n.pointee.ai_addr, n.pointee.ai_addrlen,
                                   &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        // IPv6 のスコープ ID (%en0) は分類に不要
                        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                        let text = String(decoding: bytes, as: UTF8.self)
                        out.append(text.split(separator: "%").first.map(String.init) ?? "")
                    }
                    node = n.pointee.ai_next
                }
                cont.resume(returning: out.filter { !$0.isEmpty })
            }
        }
    }
}
