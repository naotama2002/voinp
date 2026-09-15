import Foundation
import Testing
import VoinpCore
@testable import VoinpNet

/// 旗印を CI の失敗として固定する。
///
/// > **デフォルト起動状態では、音声データを外部に一切送信しない。**
///
/// この文言が成り立つ根拠は「既定設定から `.transcribe` が導出されないこと」に尽きる。
/// 実装を読んで確かめるのではなく、**壊れたらテストが落ちる**形にしておく。
@Suite("旗印 — 既定で音声が出ないこと")
struct AudioEgressGoldenTests {

    /// 5 条件をすべて満たした設定。ここから 1 つずつ崩して検査する。
    static func fullyEnabled() -> Settings {
        var s = Settings()
        s.privacy.allowNetwork = true
        s.privacy.allowedEgressClasses = ["loopback", "privateNetwork", "publicInternet"]
        s.transcription.provider = CloudTranscriptionProviderID.openAIRealtime
        s.transcription.realtime.endpointURL =
            "wss://example.openai.azure.com/openai/v1/realtime?intent=transcription"
        s.privacy.audioEgress.consentedHost = "example.openai.azure.com"
        s.privacy.audioEgress.noticeVersion = AudioEgressNotice.currentVersion
        return s
    }

    // MARK: - 既定の状態

    /// **これが旗印そのもの。**
    @Test("既定設定では transcribe が許可されない")
    func defaultDeniesTranscribe() {
        let snapshot = EgressPolicySnapshot.derive(from: Settings(), hasConfigError: false)
        #expect(!snapshot.allowedPurposes.contains(.transcribe))
        #expect(!snapshot.masterAllow, "そもそもネットワーク自体が既定オフ")
    }

    @Test("既定設定では音声の送信先が存在しない")
    func defaultHasNoAudioDestination() {
        #expect(Settings().cloudTranscriptionDestination == nil)
    }

    // MARK: - 1 条件ずつ欠けた場合

    @Test("ネットワークを有効にしただけでは許可されない")
    func networkAloneIsNotEnough() {
        var s = Settings()
        s.privacy.allowNetwork = true
        #expect(s.cloudTranscriptionDestination == nil)
        #expect(!EgressPolicySnapshot.derive(from: s, hasConfigError: false)
            .allowedPurposes.contains(.transcribe))
    }

    @Test("エンジンをクラウドにしただけでは許可されない（同意なし）")
    func engineWithoutConsentIsNotEnough() {
        var s = Self.fullyEnabled()
        s.privacy.audioEgress = Settings.Privacy.AudioEgress()   // 同意を消す
        #expect(s.cloudTranscriptionDestination == nil)
        #expect(!EgressPolicySnapshot.derive(from: s, hasConfigError: false)
            .allowedPurposes.contains(.transcribe))
    }

    /// **接続先を変えたら同意が失効すること。**
    /// 同意した相手と実際に送る相手が食い違ってはいけない。
    @Test("同意したホストと接続先が食い違えば許可されない")
    func consentIsHostScoped() {
        var s = Self.fullyEnabled()
        s.transcription.realtime.endpointURL = "wss://other.openai.azure.com/openai/v1/realtime"
        #expect(s.cloudTranscriptionDestination == nil, "別ホストへは同意が効かない")
    }

    /// 古い説明で取った同意を使い回さない。
    @Test("文面の版が古い同意は失効する")
    func staleNoticeVersionExpires() {
        var s = Self.fullyEnabled()
        s.privacy.audioEgress.noticeVersion = AudioEgressNotice.currentVersion - 1
        #expect(s.cloudTranscriptionDestination == nil)
    }

    @Test("接続先が空なら許可されない")
    func emptyEndpointIsNotEnough() {
        var s = Self.fullyEnabled()
        s.transcription.realtime.endpointURL = ""
        #expect(s.cloudTranscriptionDestination == nil)
    }

    @Test("設定が壊れていたら全条件を満たしていても denyAll")
    func configErrorDeniesEverything() {
        let snapshot = EgressPolicySnapshot.derive(from: Self.fullyEnabled(), hasConfigError: true)
        #expect(snapshot == .denyAll)
    }

    // MARK: - 全部揃ったときだけ通る

    @Test("5 条件が揃えば音声の送信先が現れる")
    func allConditionsEnableAudio() {
        let s = Self.fullyEnabled()
        let destination = s.cloudTranscriptionDestination
        #expect(destination?.host == "example.openai.azure.com")
        #expect(destination?.port == 443)
        #expect(EgressPolicySnapshot.derive(from: s, hasConfigError: false)
            .allowedPurposes.contains(.transcribe))
    }

    // MARK: - 網羅

    /// **この検査が旗印の本体。**
    ///
    /// 5 つの独立した条件の全組合せ 32 通りを回し、
    /// **すべて true のときだけ**音声の送信先が現れることを確かめる。
    /// 条件を 1 つ増やし忘れる、論理積を論理和に書き間違える、といった事故を拾う。
    @Test("5 条件の全組合せで、全部揃ったときだけ音声が出る", arguments: 0..<32)
    func exhaustiveCombinations(mask: Int) {
        let network = mask & 1 != 0
        let engine = mask & 2 != 0
        let endpoint = mask & 4 != 0
        let consent = mask & 8 != 0
        let version = mask & 16 != 0

        var s = Settings()
        s.privacy.allowNetwork = network
        s.transcription.provider = engine
            ? CloudTranscriptionProviderID.openAIRealtime
            : CloudTranscriptionProviderID.appleSpeechAnalyzer
        s.transcription.realtime.endpointURL = endpoint
            ? "wss://example.openai.azure.com/openai/v1/realtime" : ""
        s.privacy.audioEgress.consentedHost = consent ? "example.openai.azure.com" : ""
        s.privacy.audioEgress.noticeVersion = version ? AudioEgressNotice.currentVersion : 0

        let allConditionsMet = network && engine && endpoint && consent && version
        let hasDestination = s.cloudTranscriptionDestination != nil
        let detail = "mask=\(mask) network=\(network) engine=\(engine) "
            + "endpoint=\(endpoint) consent=\(consent) version=\(version)"
        #expect(hasDestination == allConditionsMet, "\(detail)")
    }

    // MARK: - 直交性

    /// 探索候補の抜け道で音声を送れないこと。
    /// `allows(host:purpose:at:)` は候補を `.modelDiscovery` に限っている。
    @Test("探索候補は transcribe に使えない")
    func probeCandidateCannotCarryAudio() {
        let snapshot = EgressPolicySnapshot(
            masterAllow: true, maxClass: .publicInternet, allowedHosts: [],
            allowedPurposes: [.transcribe],
            probeCandidate: ProbeCandidate(host: "example.com", port: 443,
                                           expiresAt: .now.advanced(by: .seconds(60))))
        #expect(!snapshot.allows(host: "example.com", purpose: .transcribe, at: .now))
        #expect(snapshot.allows(host: "example.com", purpose: .modelDiscovery, at: .now))
    }

    /// 音声を出しても、校正の送信先が勝手に生えないこと（その逆も）。
    @Test("音声と書き起こしの許可は独立している")
    func audioAndRefineAreIndependent() {
        var audioOnly = Self.fullyEnabled()
        audioOnly.refinement.enabled = false
        let a = EgressPolicySnapshot.derive(from: audioOnly, hasConfigError: false)
        #expect(a.allowedHosts == ["example.openai.azure.com"],
                "校正の送信先は生えない")

        var refineOnly = Settings()
        refineOnly.privacy.allowNetwork = true
        refineOnly.refinement.enabled = true
        refineOnly.refinement.openaiCompatible.baseURL = "https://llm.example.co.jp/v1"
        let r = EgressPolicySnapshot.derive(from: refineOnly, hasConfigError: false)
        #expect(!r.allowedPurposes.contains(.transcribe), "校正だけでは音声は出ない")
    }

    /// クラウドをループバックのサーバに向けた場合、音声は Mac から出ない。
    /// 自前の Realtime 互換サーバを立てる構成で効く。
    @Test("loopback 宛なら到達範囲は loopback のまま")
    func loopbackEndpointStaysLocal() {
        var s = Self.fullyEnabled()
        s.transcription.realtime.endpointURL = "ws://127.0.0.1:8899/v1/realtime"
        s.privacy.audioEgress.consentedHost = "127.0.0.1"
        let destination = s.cloudTranscriptionDestination
        #expect(destination?.host == "127.0.0.1")
        #expect(destination?.port == 8899)
    }
}

/// 同梱のサンプル設定が、コピーしただけで音声を出さないこと。
///
/// **実際のパーサで読む。** シェルで JSON を切り出そうとすると
/// `https://` の `//` をコメントとして消すような事故が起きる（実際に書いた）。
/// `Settings` のデコーダを通せば、JSON5 のコメントも欠損キーも本番と同じ扱いになる。
@Suite("同梱サンプル設定")
struct ConfigExampleTests {

    private func loadExample() throws -> Settings {
        // テストの実行位置に依存しないよう、このファイルから辿る
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoinpNetTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリ直下
        let data = try Data(contentsOf: root.appendingPathComponent("config.example.jsonc"))
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        return try decoder.decode(Settings.self, from: data)
    }

    @Test("サンプルをコピーしても音声は出ない")
    func exampleKeepsFlagship() throws {
        let s = try loadExample()
        #expect(s.privacy.allowNetwork == false, "マスタースイッチは既定オフ")
        #expect(s.transcription.provider == CloudTranscriptionProviderID.appleSpeechAnalyzer,
                "認識エンジンはローカル")
        #expect(s.privacy.audioEgress.consentedHost.isEmpty, "同意が書かれていない")
        #expect(s.cloudTranscriptionDestination == nil, "音声の送信先が存在しない")
    }

    @Test("サンプルが現行のスキーマで読める")
    func exampleParses() throws {
        _ = try loadExample()   // 投げなければ読めている
    }
}
