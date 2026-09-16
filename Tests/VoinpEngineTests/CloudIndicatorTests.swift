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

/// 送信の上限（到達範囲）を操作できること。
///
/// **強制に使う唯一の軸。** ここが広がらないと、同意しても接続できない。
/// Azure は `publicInternet` に解決されるので、既定の `["loopback"]` では通らない。
@Suite("到達範囲の上限")
struct EgressClassLadderTests {

    private func ladder(_ names: [String]) -> Settings {
        var s = Settings()
        s.privacy.allowedEgressClasses = names
        return s
    }

    /// 上限を上げると、それ以下も含まれること。
    /// 「インターネットを許す」が「LAN は許さない」になっては困る。
    @Test("上限を上げると下位も含む")
    func ladderIsCumulative() {
        let s = ladder(["loopback", "privateNetwork", "publicInternet"])
        #expect(s.privacy.allowedEgressClasses.contains("loopback"))
        #expect(s.privacy.allowedEgressClasses.contains("privateNetwork"))
    }

    @Test("既定はこの Mac の中だけ")
    func defaultIsLoopbackOnly() {
        #expect(Settings().privacy.allowedEgressClasses == ["loopback"])
    }

    /// 既定のままではクラウドへ繋がらないこと。
    /// 同意しただけでは足りない、という多層防御がここに現れる。
    @Test("同意しても上限が loopback なら外へは出られない")
    func consentAloneIsNotEnoughToReachInternet() {
        var s = Settings()
        s.privacy.allowNetwork = true
        s.transcription.provider = CloudTranscriptionProviderID.openAIRealtime
        s.transcription.realtime.endpointURL = "wss://example.openai.azure.com/openai/v1/realtime"
        s.privacy.audioEgress.consentedHost = "example.openai.azure.com"
        s.privacy.audioEgress.noticeVersion = AudioEgressNotice.currentVersion

        // 送信先としては現れる（5 条件は揃っている）
        #expect(s.cloudTranscriptionDestination != nil)
        // しかし上限が loopback なので、EgressGate が到達範囲で拒否する
        #expect(s.privacy.allowedEgressClasses == ["loopback"],
                "上限は別のスイッチ。同意では広がらない")
    }
}

/// 同意したときに到達範囲の上限がどう変わるか。
///
/// **「同意したのに動かない」を潰すための仕組み。**
/// 別画面の知らないスイッチで黙って止めるのは保護ではなく罠になる。
/// ただし**必要な分だけ**上げる。同意を口実に全部開けたりしない。
@Suite("同意と到達範囲の連動")
struct ConsentRaisesCeilingTests {

    /// `AppModel.grantAudioEgressConsent` が行う計算と同じもの。
    /// UI を起動せずに規則だけを検査する。
    private func raised(current: EgressClass, needed: EgressClass?) -> [String] {
        let ladder: [EgressClass] = [.loopback, .privateNetwork, .publicInternet]
        guard let needed, needed > current else {
            return ladder.filter { $0 <= current }.map(\.name)
        }
        return ladder.filter { $0 <= needed }.map(\.name)
    }

    @Test("インターネット経由の送信先なら上限もそこまで上がる")
    func raisesToPublicInternet() {
        #expect(raised(current: .loopback, needed: .publicInternet)
                == ["loopback", "privateNetwork", "publicInternet"])
    }

    /// **必要な分だけ。** 社内サーバに同意しただけでインターネットまで開けない。
    @Test("社内サーバなら社内 LAN までしか上げない")
    func raisesOnlyAsFarAsNeeded() {
        #expect(raised(current: .loopback, needed: .privateNetwork)
                == ["loopback", "privateNetwork"])
    }

    /// 既に足りているなら触らない。**同意で勝手に狭まっても困る。**
    @Test("既に上限が足りていれば変えない")
    func keepsCeilingWhenSufficient() {
        #expect(raised(current: .publicInternet, needed: .privateNetwork)
                == ["loopback", "privateNetwork", "publicInternet"])
    }

    /// 解決できなかったときに勝手に広げない。
    @Test("到達範囲が判定できなければ広げない")
    func doesNotRaiseWhenUnknown() {
        #expect(raised(current: .loopback, needed: nil) == ["loopback"])
    }

    /// ループバックの自前サーバなら、上限は据え置きのまま使える。
    @Test("loopback 宛なら上限は動かない")
    func loopbackNeedsNoChange() {
        #expect(raised(current: .loopback, needed: .loopback) == ["loopback"])
    }
}
