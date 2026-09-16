import Foundation
import Testing
import VoinpCore
@testable import VoinpEngine

/// 設定に従って認識エンジンが切り替わること。
///
/// **旗印に直結する。** ここでクラウドが選ばれる条件を独自に書き足すと、
/// `cloudTranscriptionDestination` の 5 条件を迂回する経路ができる。
@Suite("認識エンジンの選択")
struct RoutingProviderTests {

    /// どちらが選ばれたかを identifier で見分けるためのフェイク。
    struct NamedProvider: TranscriptionProvider {
        let identifier: String
        func readiness(for request: TranscriptionRequest) async -> Readiness { .ready }
        func downloadModel(for locale: Locale,
                           progress: @Sendable @escaping (Double) -> Void) async throws {}
        /// **どちらが選ばれたかを見分けるための差。**
        /// 同じ値を返すと「ローカルに倒れた」を検査したつもりで何も見ていない
        /// （最初そう書いて、わざと壊しても落ちないことで気づいた）。
        func preferredFormat(for request: TranscriptionRequest) async -> AudioFormatDescription {
            AudioFormatDescription(sampleRate: identifier == "cloud" ? 24_000 : 16_000,
                                   channelCount: 1, isInt16: true)
        }
        func startSession(_ request: TranscriptionRequest) async throws
            -> any TranscriptionSession {
            struct Unused: Error {}
            throw Unused()
        }
    }

    private func enabledSettings() -> Settings {
        var s = Settings()
        s.privacy.allowNetwork = true
        s.transcription.provider = CloudTranscriptionProviderID.openAIRealtime
        s.transcription.realtime.endpointURL = "wss://example.com/v1/realtime"
        s.privacy.audioEgress.consentedHost = "example.com"
        s.privacy.audioEgress.noticeVersion = AudioEgressNotice.currentVersion
        return s
    }

    private func router(_ settings: Settings,
                        cloudAvailable: Bool = true) -> RoutingTranscriptionProvider {
        let cloudFactory: @Sendable (Settings) -> (any TranscriptionProvider)? = { _ in
            NamedProvider(identifier: "cloud")
        }
        let make: (@Sendable (Settings) -> (any TranscriptionProvider)?)? =
            cloudAvailable ? cloudFactory : nil
        return RoutingTranscriptionProvider(
            local: NamedProvider(identifier: "local"),
            makeCloud: make,
            settings: settings)
    }

    @Test("既定ではローカルを使う")
    func defaultUsesLocal() async {
        let format = await router(Settings()).preferredFormat(
            for: TranscriptionRequest(locale: Locale(identifier: "ja-JP")))
        #expect(format.sampleRate == 16_000, "ローカルのフォーマット")
    }

    /// 5 条件が揃うとクラウドが一次になる。退避先がローカルなので
    /// `FallbackTranscriptionProvider` 経由になり、identifier は一次のものになる。
    @Test("5 条件が揃うとクラウドが一次になる")
    func enabledUsesCloud() async {
        let r = router(enabledSettings())
        let format = await r.preferredFormat(
            for: TranscriptionRequest(locale: Locale(identifier: "ja-JP")))
        #expect(format.sampleRate == 24_000, "クラウドのフォーマットで取り込むこと")
        #expect(!r.cloudSelectedButUnavailable)
    }

    /// **同意が無ければクラウドにならない。** ルータが独自の条件で判断していないこと。
    @Test("同意が無ければローカルのまま")
    func withoutConsentStaysLocal() async {
        var s = enabledSettings()
        s.privacy.audioEgress = Settings.Privacy.AudioEgress()
        let format = await router(s).preferredFormat(
            for: TranscriptionRequest(locale: Locale(identifier: "ja-JP")))
        #expect(format.sampleRate == 16_000, "ローカルに倒れること")
    }

    @Test("ネットワークが無効ならローカルのまま")
    func withoutNetworkStaysLocal() async {
        var s = enabledSettings()
        s.privacy.allowNetwork = false
        let format = await router(s).preferredFormat(
            for: TranscriptionRequest(locale: Locale(identifier: "ja-JP")))
        #expect(format.sampleRate == 16_000)
    }

    /// **オフライン版の挙動。** クラウドの実装が無いので必ずローカルに倒れる。
    /// ただし黙らない — 呼び出し側が気づけるようにする。
    @Test("実装が無ければローカルに倒れ、それが分かる")
    func offlineFallsBackAndReportsIt() async {
        let r = router(enabledSettings(), cloudAvailable: false)
        let format = await r.preferredFormat(
            for: TranscriptionRequest(locale: Locale(identifier: "ja-JP")))
        #expect(format.sampleRate == 16_000, "ローカルに倒れること")
        #expect(r.cloudSelectedButUnavailable, "選ばれているのに使えないと分かること")
    }

    /// 設定を変えたら次のセッションから反映されること。
    /// 起動時にコピーして抱えると、再起動するまで効かない。
    @Test("設定変更が次のセッションから効く")
    func settingsChangeTakesEffect() async {
        let r = router(Settings())
        let before = await r.preferredFormat(
            for: TranscriptionRequest(locale: Locale(identifier: "ja-JP")))
        #expect(before.sampleRate == 16_000)

        r.settingsChanged(enabledSettings())
        let after = await r.preferredFormat(
            for: TranscriptionRequest(locale: Locale(identifier: "ja-JP")))
        #expect(after.sampleRate == 24_000, "変更後はクラウドになること")
    }
}
