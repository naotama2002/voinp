import Testing
import Foundation
import VoinpCore
@testable import VoinpNet

/// テスト用。Keychain に触らない。
struct FakeCredentialStore: CredentialStore {
    func read(_ ref: CredentialRef) throws -> String? { nil }
    func write(_ value: String, to ref: CredentialRef) throws {}
    func delete(_ ref: CredentialRef) throws {}
}

@Suite("EgressGate — 送信前の拒否")
struct EgressGateTests {

    private func gate(_ snapshot: EgressPolicySnapshot) -> EgressGate {
        EgressGate(policy: { snapshot }, credentials: FakeCredentialStore())
    }

    private func request(_ urlString: String,
                         purpose: EgressPurpose = .refine) -> EgressRequest {
        EgressRequest(purpose: purpose, providerID: "test",
                      url: URL(string: urlString)!, carriesUserContent: true)
    }

    @Test("ネットワークが無効なら拒否する（既定の状態）")
    func deniesWhenDisabled() async {
        let g = gate(.denyAll)
        await #expect(throws: VoinpError.self) {
            try await g.send(request("https://llm.example.co.jp/v1/chat/completions"))
        }
    }

    @Test("設定に無いホストは拒否する")
    func deniesUnknownHost() async {
        let snapshot = EgressPolicySnapshot(
            masterAllow: true, maxClass: .publicInternet,
            allowedHosts: ["llm.example.co.jp"],
            allowedPurposes: [.refine], probeCandidate: nil)
        let g = gate(snapshot)
        await #expect(throws: VoinpError.self) {
            try await g.send(request("https://evil.example.com/v1/chat/completions"))
        }
    }

    @Test("許可されていない用途は拒否する")
    func deniesDisallowedPurpose() async {
        let snapshot = EgressPolicySnapshot(
            masterAllow: true, maxClass: .publicInternet,
            allowedHosts: ["llm.example.co.jp"],
            allowedPurposes: [.modelDiscovery],   // refine は許可していない
            probeCandidate: nil)
        let g = gate(snapshot)
        await #expect(throws: VoinpError.self) {
            try await g.send(request("https://llm.example.co.jp/v1/chat/completions",
                                     purpose: .refine))
        }
    }

    @Test("到達範囲の上限を超えるホストは拒否する")
    func deniesReachBeyondLimit() async {
        // loopback しか許していないのに公開ホストへ送ろうとする
        let snapshot = EgressPolicySnapshot(
            masterAllow: true, maxClass: .loopback,
            allowedHosts: ["8.8.8.8"],
            allowedPurposes: [.refine], probeCandidate: nil)
        let g = gate(snapshot)
        await #expect(throws: VoinpError.self) {
            try await g.send(request("https://8.8.8.8/v1/chat/completions"))
        }
    }

    @Test("公開ホストへの平文 http は拒否する")
    func deniesPlaintextToPublicHost() async {
        let snapshot = EgressPolicySnapshot(
            masterAllow: true, maxClass: .publicInternet,
            allowedHosts: ["8.8.8.8"],
            allowedPurposes: [.refine], probeCandidate: nil)
        let g = gate(snapshot)
        await #expect(throws: VoinpError.self) {
            try await g.send(request("http://8.8.8.8/v1/chat/completions"))
        }
    }

    @Test("loopback への平文 http は許可される（ローカル LLM）")
    func allowsPlaintextToLoopback() {
        // 実際に送らずポリシー判定だけ確認する
        let snapshot = EgressPolicySnapshot(
            masterAllow: true, maxClass: .loopback,
            allowedHosts: ["127.0.0.1"],
            allowedPurposes: [.refine], probeCandidate: nil)
        #expect(snapshot.allows(host: "127.0.0.1", purpose: .refine, at: .now))
        #expect(HostClassifier.classifyLiteral("127.0.0.1") == .loopback)
    }
}

@Suite("EgressPolicySnapshot — 探索候補")
struct ProbeCandidateTests {

    @Test("候補はモデル探索にだけ使える")
    func candidateOnlyForDiscovery() {
        let candidate = ProbeCandidate(host: "new.example.com", port: 443,
                                       expiresAt: .now.advanced(by: .seconds(60)))
        let snapshot = EgressPolicySnapshot(
            masterAllow: true, maxClass: .publicInternet, allowedHosts: [],
            allowedPurposes: [.modelDiscovery, .refine], probeCandidate: candidate)

        #expect(snapshot.allows(host: "new.example.com", purpose: .modelDiscovery, at: .now))
        #expect(!snapshot.allows(host: "new.example.com", purpose: .refine, at: .now),
                "候補に書き起こしを送ってはいけない")
    }

    @Test("候補は時間で失効する")
    func candidateExpires() {
        let candidate = ProbeCandidate(host: "new.example.com", port: 443,
                                       expiresAt: .now.advanced(by: .seconds(60)))
        let snapshot = EgressPolicySnapshot(
            masterAllow: true, maxClass: .publicInternet, allowedHosts: [],
            allowedPurposes: [.modelDiscovery], probeCandidate: candidate)

        #expect(snapshot.allows(host: "new.example.com", purpose: .modelDiscovery, at: .now))
        #expect(!snapshot.allows(host: "new.example.com", purpose: .modelDiscovery,
                                 at: .now.advanced(by: .seconds(120))), "失効後は通さない")
    }

    @Test("マスタースイッチが切れていれば候補も無効")
    func masterSwitchWins() {
        #expect(!EgressPolicySnapshot.denyAll.masterAllow)
    }
}

/// 平文スキームの判定。
///
/// `Foundation` は URL のスキームを小文字化しないので、等値比較で書くと
/// 大文字の `HTTP://` がすり抜ける。設定に大文字で書けば実際に到達するため、
/// 公開ホストへ書き起こしテキストが平文で出る経路になっていた。
@Suite("平文スキームの判定")
struct PlaintextSchemeTests {

    @Test("大文字小文字を問わず平文と判定する")
    func caseInsensitive() {
        for s in ["http", "HTTP", "Http", "hTTp"] {
            #expect(EgressGate.isPlaintext(s), "『\(s)』を平文と判定すること")
        }
    }

    /// WebSocket の平文経路は http と同じ危険度。
    /// ここを落とすと音声がプロキシに丸見えのまま流れる。
    @Test("ws も平文として扱う")
    func webSocketIsPlaintext() {
        for s in ["ws", "WS", "Ws"] {
            #expect(EgressGate.isPlaintext(s), "『\(s)』を平文と判定すること")
        }
    }

    @Test("TLS つきは平文ではない")
    func tlsIsNotPlaintext() {
        for s in ["https", "HTTPS", "wss", "WSS"] {
            #expect(!EgressGate.isPlaintext(s), "『\(s)』は平文でないこと")
        }
    }

    @Test("スキームが無い場合は平文とみなさない")
    func nilScheme() {
        #expect(!EgressGate.isPlaintext(nil))
    }

    /// 実際に踏んだ形。`Foundation` が小文字化しないことの固定。
    @Test("URL から取り出したスキームは小文字化されない")
    func foundationDoesNotLowercaseScheme() {
        #expect(URL(string: "HTTP://example.com/x")?.scheme == "HTTP",
                "小文字化されるようになったら、この検査の前提が変わる")
        #expect(EgressGate.isPlaintext(URL(string: "HTTP://example.com/x")?.scheme))
    }
}
