import Foundation
import Testing
import VoinpCore

/// 「音声が外に出る状態」が表示に必ず出ること。
///
/// **表示と実際の経路が食い違うのが一番よくない。**
/// 旗印は「既定では出さない」であって「出ていることを隠す」ではないので、
/// 出る状態になったら常に見えていなければならない。
@Suite("クラウド利用時の表示")
struct CloudIndicatorTests {

    private func enabled() -> Settings {
        var s = Settings()
        s.privacy.allowNetwork = true
        s.transcription.provider = CloudTranscriptionProviderID.openAIRealtime
        s.transcription.realtime.endpointURL = "wss://example.com/v1/realtime"
        s.privacy.audioEgress.consentedHost = "example.com"
        s.privacy.audioEgress.noticeVersion = AudioEgressNotice.currentVersion
        return s
    }

    @Test("有効なら送信先が取れる")
    func destinationAvailable() {
        #expect(enabled().cloudTranscriptionDestination?.host == "example.com")
    }

    @Test("既定なら送信先が無い")
    func noDestinationByDefault() {
        #expect(Settings().cloudTranscriptionDestination == nil)
    }

    /// 同意を取り消したらローカルに戻り、**同意の記録も消える**こと。
    /// 残すと次に有効化したときに確認が出ない。
    @Test("同意の取り消しで記録ごと消える")
    func revokeClearsRecord() {
        var s = enabled()
        s.privacy.audioEgress = Settings.Privacy.AudioEgress()
        s.transcription.provider = CloudTranscriptionProviderID.appleSpeechAnalyzer
        #expect(s.cloudTranscriptionDestination == nil)
        #expect(s.privacy.audioEgress.consentedHost.isEmpty)
        #expect(s.privacy.audioEgress.noticeVersion == 0)
    }

    /// 同意した記録が残ること（プライバシー画面に出すため）。
    @Test("同意すると日時と版が記録される")
    func consentIsRecorded() {
        var s = Settings()
        s.privacy.allowNetwork = true
        s.transcription.realtime.endpointURL = "wss://example.com/v1/realtime"
        s.privacy.audioEgress.consentedHost = "example.com"
        s.privacy.audioEgress.consentedAt = "2026-09-15T00:00:00Z"
        s.privacy.audioEgress.noticeVersion = AudioEgressNotice.currentVersion
        s.transcription.provider = CloudTranscriptionProviderID.openAIRealtime
        #expect(s.privacy.audioEgress.consentedAt != nil)
        #expect(s.cloudTranscriptionDestination != nil)
    }
}
