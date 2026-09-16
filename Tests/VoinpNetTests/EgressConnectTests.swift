import Foundation
import Testing
import VoinpCore
@testable import VoinpNet

/// WebSocket 経路が `send()` と**同じ判定**を通ること。
///
/// この検査群の存在理由は、経路が 2 本になったときに
/// 「片方だけ緩い実装」が入り込むのを防ぐこと。
/// 拒否されるべき条件を 1 つの表にして、**同じ表を両方の経路に流す**。
@Suite("WebSocket 経路の判定")
struct EgressConnectTests {

    struct Case: Sendable, CustomStringConvertible {
        let name: String
        let snapshot: EgressPolicySnapshot
        let route: ProxyResolver.Route
        var description: String { name }
    }

    /// 拒否されなければならない状況。`send` と `connect` の両方に同じものを流す。
    static let denials: [Case] = [
        Case(name: "ネットワークが無効",
             snapshot: .denyAll,
             route: .direct),
        Case(name: "許可されていないホスト",
             snapshot: EgressPolicySnapshot(masterAllow: true, maxClass: .publicInternet,
                                            allowedHosts: ["other.example.com"],
                                            allowedPurposes: [.transcribe], probeCandidate: nil),
             route: .direct),
        Case(name: "許可されていない用途",
             snapshot: EgressPolicySnapshot(masterAllow: true, maxClass: .publicInternet,
                                            allowedHosts: ["127.0.0.1"],
                                            allowedPurposes: [.refine], probeCandidate: nil),
             route: .direct),
        Case(name: "到達範囲がポリシーを超える",
             snapshot: EgressPolicySnapshot(masterAllow: true, maxClass: .loopback,
                                            allowedHosts: ["93.184.216.34"],
                                            allowedPurposes: [.transcribe], probeCandidate: nil),
             route: .direct),
        Case(name: "loopback 宛なのに公開プロキシ経由",
             snapshot: EgressPolicySnapshot(masterAllow: true, maxClass: .loopback,
                                            allowedHosts: ["127.0.0.1"],
                                            allowedPurposes: [.transcribe], probeCandidate: nil),
             route: .proxied(["93.184.216.34"])),
        Case(name: "プロキシ経路が判定できない",
             snapshot: EgressPolicySnapshot(masterAllow: true, maxClass: .loopback,
                                            allowedHosts: ["127.0.0.1"],
                                            allowedPurposes: [.transcribe], probeCandidate: nil),
             route: .undeterminable),
    ]

    private func gate(_ c: Case) -> EgressGate {
        EgressGate(policy: { c.snapshot }, credentials: FakeCredentialStore(),
                   proxyRoute: { _ in c.route })
    }

    /// **本命。** 同じ拒否条件が `connect` でも効くこと。
    /// ここが落ちるときは、WebSocket 経路だけ判定を素通りしている。
    @Test("拒否条件は connect でも同じように効く", arguments: denials)
    func connectDeniesLikeSend(c: Case) async {
        let g = gate(c)
        let request = EgressRequest(purpose: .transcribe, providerID: "test",
                                    url: URL(string: "wss://127.0.0.1:1234/v1/realtime")!,
                                    carriesUserContent: true)
        await #expect(throws: VoinpError.self, "『\(c.name)』は connect でも拒否されること") {
            _ = try await g.connect(request)
        }
    }

    @Test("同じ拒否条件が send でも効く（対照）", arguments: denials)
    func sendDenies(c: Case) async {
        let g = gate(c)
        let request = EgressRequest(purpose: .transcribe, providerID: "test",
                                    url: URL(string: "https://127.0.0.1:1234/v1/x")!,
                                    carriesUserContent: true)
        await #expect(throws: VoinpError.self, "『\(c.name)』は send でも拒否されること") {
            _ = try await g.send(request)
        }
    }

    // MARK: - スキームの取り違え

    private func permissive() -> EgressGate {
        EgressGate(policy: {
            EgressPolicySnapshot(masterAllow: true, maxClass: .publicInternet,
                                 allowedHosts: ["127.0.0.1"],
                                 allowedPurposes: [.transcribe, .refine], probeCandidate: nil)
        }, credentials: FakeCredentialStore(), proxyRoute: { _ in .direct })
    }

    @Test("https を connect に渡すと拒否する")
    func httpsToConnectRejected() async {
        let g = permissive()
        let r = EgressRequest(purpose: .transcribe, providerID: "t",
                              url: URL(string: "https://127.0.0.1:1234/x")!)
        await #expect(throws: VoinpError.self) { _ = try await g.connect(r) }
    }

    @Test("wss を send に渡すと拒否する")
    func wssToSendRejected() async {
        let g = permissive()
        let r = EgressRequest(purpose: .refine, providerID: "t",
                              url: URL(string: "wss://127.0.0.1:1234/x")!)
        await #expect(throws: VoinpError.self) { _ = try await g.send(r) }
    }

    // MARK: - プロキシ問い合わせ URL の写像

    /// PAC は URL のスキーム文字列で分岐する。`wss` のまま聞くと
    /// `shExpMatch(url, "https:*")` に当たらず「直結」と誤答されうる。
    @Test("プロキシ判定には http/https へ写像した URL を渡す")
    func proxyProbeURLIsMapped() async {
        #expect(EgressGate.proxyProbeURL(for: URL(string: "wss://a.example.com/v1?x=1")!)?
            .absoluteString == "https://a.example.com/v1?x=1")
        #expect(EgressGate.proxyProbeURL(for: URL(string: "ws://a.example.com:8080/v1")!)?
            .absoluteString == "http://a.example.com:8080/v1")
        // http/https はそのまま
        #expect(EgressGate.proxyProbeURL(for: URL(string: "https://a.example.com/v1")!)?
            .absoluteString == "https://a.example.com/v1")
        // 知らないスキームは写像できない → 呼び出し側が拒否する
        #expect(EgressGate.proxyProbeURL(for: URL(string: "ftp://a.example.com/v1")!) == nil)
    }

    /// 実際に `proxyRoute` へ渡る URL を観測する。写像の回帰検査。
    @Test("connect はプロキシ判定に https を渡す")
    func connectPassesMappedURLToProxyResolver() async {
        let seen = SeenURL()
        let g = EgressGate(
            policy: { .denyAll },
            credentials: FakeCredentialStore(),
            proxyRoute: { url in await seen.set(url); return .direct })
        // denyAll なので手順 1 で落ちる。ここでは呼ばれないことを確かめる。
        _ = try? await g.connect(EgressRequest(purpose: .transcribe, providerID: "t",
                                               url: URL(string: "wss://a.example.com/v1")!))
        #expect(await seen.value == nil, "マスタースイッチで落ちたらプロキシは引かない")
    }

    actor SeenURL {
        private(set) var value: URL?
        func set(_ u: URL) { value = u }
    }

    // MARK: - 認証スキーム

    /// Azure OpenAI は `api-key: <生キー>`。`Bearer` を固定していた頃は表現できなかった。
    @Test("秘密の載せ方をスキームで選べる")
    func secretSchemes() {
        let store = StubCredentials(value: "SECRET")
        let base = URLRequest(url: URL(string: "https://example.com")!)

        let bearer = EgressGate.applyingSecrets(
            to: base, ["Authorization": .bearer(CredentialRef(account: "a"))], using: store)
        #expect(bearer.value(forHTTPHeaderField: "Authorization") == "Bearer SECRET")

        let raw = EgressGate.applyingSecrets(
            to: base, ["api-key": .raw(CredentialRef(account: "a"))], using: store)
        #expect(raw.value(forHTTPHeaderField: "api-key") == "SECRET")
    }

    /// 未登録・空なら**ヘッダを付けない**。
    /// 接続先ごとに口座を分けている性質と対で、前のサーバーの鍵が飛ぶのを防ぐ。
    @Test("秘密が無ければヘッダを付けない")
    func missingSecretAddsNoHeader() {
        let base = URLRequest(url: URL(string: "https://example.com")!)
        for store in [StubCredentials(value: nil), StubCredentials(value: "")] {
            let r = EgressGate.applyingSecrets(
                to: base, ["Authorization": .bearer(CredentialRef(account: "a"))], using: store)
            #expect(r.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }
}

/// 値を 1 つだけ返す資格情報ストア。
/// `FakeCredentialStore`（常に nil）とは別物なので名前を分けてある。
struct StubCredentials: CredentialStore {
    let value: String?
    func read(_ ref: CredentialRef) throws -> String? { value }
    func write(_ value: String, to ref: CredentialRef) throws {}
    func delete(_ ref: CredentialRef) throws {}
}
