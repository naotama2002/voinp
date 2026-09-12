import Testing
import Foundation
import VoinpCore
@testable import VoinpNet

@Suite("PrivacyPosture")
struct PrivacyPostureTests {

    /// ホスト名 → 到達範囲。実運用では DNS 解決を伴うのでテストでは固定する。
    static func resolver(_ mapping: [String: EgressClass]) -> (String) -> EgressClass {
        { mapping[$0] ?? .publicInternet }
    }

    private func settings(
        baseURL: String, allow: [String], operatorKind: String = "self-hosted",
        refinementEnabled: Bool = true, network: Bool = true
    ) -> Settings {
        var s = Settings()
        s.privacy.allowNetwork = network
        s.privacy.allowedEgressClasses = allow
        s.refinement.enabled = refinementEnabled
        s.refinement.openaiCompatible.baseURL = baseURL
        s.refinement.openaiCompatible.operatorKind = operatorKind
        return s
    }

    // ── 旗印のゴールデンテスト ──────────────────────────────

    @Test("既定設定はオフライン。送信先ゼロ")
    func defaultIsOffline() {
        let p = PrivacyPosture.evaluate(Settings(), hasConfigError: false,
                                        reachResolver: Self.resolver([:]))
        #expect(p.level == .offline)
        #expect(p.destinations.isEmpty)
        #expect(!p.audioLeavesMachine)
    }

    @Test("設定エラーなら通信を停止した状態になる")
    func configErrorForcesMisconfigured() {
        let p = PrivacyPosture.evaluate(Settings(), hasConfigError: true,
                                        reachResolver: Self.resolver([:]))
        #expect(p.level == .misconfigured)
        #expect(p.destinations.isEmpty)
    }

    // ── 3 つの接続形態 ──────────────────────────────────────

    @Test("127.0.0.1 のセルフホスト → loopbackOnly")
    func loopbackSelfHosted() {
        let s = settings(baseURL: "http://127.0.0.1:1234/v1", allow: ["loopback"])
        let p = PrivacyPosture.evaluate(s, hasConfigError: false,
                                        reachResolver: Self.resolver(["127.0.0.1": .loopback]))
        #expect(p.level == .loopbackOnly)
        #expect(p.destinations.first?.operatorKind == .selfHosted)
    }

    @Test("社内 LAN のプライベート IP → localNetwork")
    func privateNetworkSelfHosted() {
        let s = settings(baseURL: "https://10.1.2.3/v1", allow: ["loopback", "privateNetwork"])
        let p = PrivacyPosture.evaluate(s, hasConfigError: false,
                                        reachResolver: Self.resolver(["10.1.2.3": .privateNetwork]))
        #expect(p.level == .localNetwork)
        #expect(p.destinations.first?.port == 443)
    }

    @Test("社内サーバの https（公開 DNS 名）→ external だが運用主体は selfHosted")
    func publicInternetButSelfHosted() {
        let s = settings(baseURL: "https://llm.example.co.jp/v1",
                         allow: ["loopback", "privateNetwork", "publicInternet"])
        let p = PrivacyPosture.evaluate(s, hasConfigError: false,
                                        reachResolver: Self.resolver(["llm.example.co.jp": .publicInternet]))
        // 到達範囲は外。ここを甘くしてはいけない。
        #expect(p.level == .external)
        // しかし運用主体は自社。表示はこれを反映してよい。
        #expect(p.destinations.first?.operatorKind == .selfHosted)
        #expect(p.destinations.first?.reach == .publicInternet)
    }

    // ── 核心: 申告は許可も表示レベルも緩めない ──────────────

    @Test("ベンダーを self-hosted と申告してもアイコンは external のまま")
    func declarationCannotSoftenTheIcon() {
        let vendor = settings(baseURL: "https://api.openai.com/v1",
                              allow: ["loopback", "privateNetwork", "publicInternet"],
                              operatorKind: "vendor")
        let lying = settings(baseURL: "https://api.openai.com/v1",
                             allow: ["loopback", "privateNetwork", "publicInternet"],
                             operatorKind: "self-hosted")
        let r = Self.resolver(["api.openai.com": .publicInternet])
        let a = PrivacyPosture.evaluate(vendor, hasConfigError: false, reachResolver: r)
        let b = PrivacyPosture.evaluate(lying, hasConfigError: false, reachResolver: r)
        #expect(a.level == b.level)          // 申告でレベルは変わらない
        #expect(a.level == .external)
    }

    @Test("到達範囲の上限を超える設定は送信先として現れない")
    func reachCapIsEnforced() {
        // 既定の loopback のみ許可のまま、社内 https サーバを設定した場合
        let s = settings(baseURL: "https://llm.example.co.jp/v1", allow: ["loopback"])
        let p = PrivacyPosture.evaluate(s, hasConfigError: false,
                                        reachResolver: Self.resolver(["llm.example.co.jp": .publicInternet]))
        #expect(p.level == .offline)
        #expect(p.destinations.isEmpty)
    }

    // ── 旗印: 音声は LLM 送信先が増えても出ない ──────────────

    @Test("整形テキストの送信先が外部でも、音声は Mac から出ない")
    func audioNeverLeavesViaRefinement() {
        let s = settings(baseURL: "https://llm.example.co.jp/v1",
                         allow: ["loopback", "privateNetwork", "publicInternet"])
        let p = PrivacyPosture.evaluate(s, hasConfigError: false,
                                        reachResolver: Self.resolver(["llm.example.co.jp": .publicInternet]))
        #expect(p.level == .external)
        #expect(!p.audioLeavesMachine)   // 旗印はここで守られている
        #expect(p.destinations.allSatisfy { $0.dataKind == .refinedText })
    }

    @Test("校正が無効なら送信先は生えない")
    func refinementDisabledMeansOffline() {
        let s = settings(baseURL: "https://llm.example.co.jp/v1",
                         allow: ["publicInternet"], refinementEnabled: false)
        let p = PrivacyPosture.evaluate(s, hasConfigError: false,
                                        reachResolver: Self.resolver(["llm.example.co.jp": .publicInternet]))
        #expect(p.level == .offline)
    }
}
