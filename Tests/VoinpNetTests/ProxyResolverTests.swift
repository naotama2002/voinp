import Foundation
import Testing
import VoinpCore
@testable import VoinpNet

/// プロキシ経路の解釈。
///
/// ここが効かないと、宛先が `127.0.0.1` でも書き起こしが社外へ出る構成を
/// 素通しする。仕様 (docs/06-privacy.md の手順 7) は最初から書いてあったのに
/// 実装されておらず、`proxyExceedsPolicy` 等のエラーは定義だけされて
/// どこからも throw されていなかった。
@Suite("プロキシ経路の判定")
struct ProxyResolverTests {

    private func entry(_ type: CFString, host: String? = nil) -> [AnyHashable: Any] {
        var e: [AnyHashable: Any] = [kCFProxyTypeKey as String: type as String]
        if let host { e[kCFProxyHostNameKey as String] = host }
        return e
    }

    @Test("プロキシなしは直結")
    func noneIsDirect() {
        #expect(ProxyResolver.resolve([entry(kCFProxyTypeNone)]) == .direct)
    }

    @Test("HTTP プロキシはホストを返す")
    func httpProxyReturnsHost() {
        let r = ProxyResolver.resolve([entry(kCFProxyTypeHTTP, host: "proxy.example.com")])
        #expect(r == .proxied(["proxy.example.com"]))
    }

    @Test("SOCKS も経路として扱う")
    func socksIsProxied() {
        let r = ProxyResolver.resolve([entry(kCFProxyTypeSOCKS, host: "socks.internal")])
        #expect(r == .proxied(["socks.internal"]))
    }

    /// PAC は評価が要る。`resolve` 自身は通信しないので、必要だと申告して返す。
    ///
    /// **実機で踏んだ落とし穴**: `kCFProxyAutoConfigurationURLKey` の値は
    /// `String` ではなく `NSURL` で来る。`as? String` だけで取り出そうとして
    /// 常に失敗し、PAC を配る社内 Mac で通信が全部拒否された。
    @Test("PAC URL は NSURL でも String でも取り出せる")
    func pacURLIsExtracted() {
        let asURL: [AnyHashable: Any] = [
            kCFProxyTypeKey as String: kCFProxyTypeAutoConfigurationURL as String,
            kCFProxyAutoConfigurationURLKey as String: NSURL(string: "http://pac.example.com/p.pac")!,
        ]
        #expect(ProxyResolver.resolve([asURL])
                == .needsPAC(URL(string: "http://pac.example.com/p.pac")!))

        let asString: [AnyHashable: Any] = [
            kCFProxyTypeKey as String: kCFProxyTypeAutoConfigurationURL as String,
            kCFProxyAutoConfigurationURLKey as String: "http://pac.example.com/p.pac",
        ]
        #expect(ProxyResolver.resolve([asString])
                == .needsPAC(URL(string: "http://pac.example.com/p.pac")!))
    }

    @Test("PAC の URL が取れないなら判定不能")
    func pacWithoutURLIsUndeterminable() {
        #expect(ProxyResolver.resolve([entry(kCFProxyTypeAutoConfigurationURL)])
                == .undeterminable)
    }

    /// インラインの PAC スクリプトは扱わない。解釈できないものを直結とみなさない。
    @Test("インライン PAC は判定不能として拒否する")
    func inlinePACIsUndeterminable() {
        #expect(ProxyResolver.resolve([entry(kCFProxyTypeAutoConfigurationJavaScript)])
                == .undeterminable)
    }

    @Test("空の結果を直結とみなさない")
    func emptyIsUndeterminable() {
        #expect(ProxyResolver.resolve([]) == .undeterminable)
    }

    @Test("ホスト名の無いプロキシは判定不能")
    func proxyWithoutHostIsUndeterminable() {
        #expect(ProxyResolver.resolve([entry(kCFProxyTypeHTTP)]) == .undeterminable)
    }

    @Test("知らない種類は安全側へ倒す")
    func unknownTypeIsUndeterminable() {
        let e: [AnyHashable: Any] = [kCFProxyTypeKey as String: "kCFProxyTypeQuantum"]
        #expect(ProxyResolver.resolve([e]) == .undeterminable)
    }

    @Test("直結エントリと実プロキシが混ざったらプロキシ扱い")
    func mixedPrefersProxy() {
        let r = ProxyResolver.resolve([
            entry(kCFProxyTypeNone),
            entry(kCFProxyTypeHTTP, host: "proxy.example.com"),
        ])
        #expect(r == .proxied(["proxy.example.com"]))
    }
}

/// ゲートがプロキシをどう扱うか。
///
/// レビュー指摘 5「設計書で要求しているプロキシの許可判定が未実装」に対応する。
@Suite("EgressGate — プロキシ経由の判定")
struct EgressGateProxyTests {

    private func gate(_ snapshot: EgressPolicySnapshot,
                      route: @escaping @Sendable (URL) async -> ProxyResolver.Route) -> EgressGate {
        EgressGate(policy: { snapshot }, credentials: FakeCredentialStore(),
                   proxyRoute: route)
    }

    private func loopbackOnly() -> EgressPolicySnapshot {
        EgressPolicySnapshot(masterAllow: true, maxClass: .loopback,
                             allowedHosts: ["127.0.0.1"],
                             allowedPurposes: [.refine], probeCandidate: nil)
    }

    private func request(_ s: String) -> EgressRequest {
        EgressRequest(purpose: .refine, providerID: "test",
                      url: URL(string: s)!, carriesUserContent: true)
    }

    /// **この検査の存在理由。**
    /// ローカルの LLM を指しているのに、システムのプロキシ設定で社外へ出て行く構成。
    /// 宛先ホストだけを見ていると loopback と判定して素通ししてしまう。
    @Test("loopback 宛でも公開プロキシ経由なら拒否する")
    func loopbackViaPublicProxyDenied() async {
        let g = gate(loopbackOnly(), route: { _ in .proxied(["proxy.example.com"]) })
        await #expect(throws: VoinpError.self) {
            try await g.send(request("http://127.0.0.1:1234/v1/chat/completions"))
        }
    }

    /// PAC を評価しないまま「たぶん直結」で送らないこと。
    @Test("経路が判定できないなら拒否する（fail closed）")
    func undeterminableDenied() async {
        let g = gate(loopbackOnly(), route: { _ in .undeterminable })
        await #expect(throws: VoinpError.self) {
            try await g.send(request("http://127.0.0.1:1234/v1/chat/completions"))
        }
    }

    /// 緩めすぎて常時拒否になっていないことの確認。
    /// 直結なら従来どおり宛先の分類だけで通る（この URL は接続失敗するが、
    /// **ゲートでの拒否ではない**ことを確かめたいので拒否理由を見る）。
    @Test("直結なら宛先の分類だけで判定する")
    func directIsNotBlockedByProxyCheck() async {
        let g = gate(loopbackOnly(), route: { _ in .direct })
        do {
            _ = try await g.send(request("http://127.0.0.1:9/v1/chat/completions"))
        } catch let e as VoinpError {
            if case .egressDenied(let reason) = e {
                Issue.record("直結なのにゲートが拒否した: \(reason)")
            }
            // 接続そのものの失敗（ポート 9 は discard）は想定どおり。
        } catch {
            // URLError 等。ゲートは通過している。
        }
    }
}
