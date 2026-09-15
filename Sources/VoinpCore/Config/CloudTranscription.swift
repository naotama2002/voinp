import Foundation

/// クラウド認識の送信先。
public struct CloudTranscriptionDestination: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let providerID: String
    /// 申告。**表示にしか使わない。許可を広げない。**
    public let operatorKind: String

    public init(host: String, port: Int, providerID: String, operatorKind: String) {
        self.host = host
        self.port = port
        self.providerID = providerID
        self.operatorKind = operatorKind
    }
}

public enum AudioEgressNotice {
    /// 同意文面の版。
    /// **文面を実質的に変えたら上げること。** 上げると全員の同意が失効し、
    /// 次に使うときに再確認が出る。古い説明で取った同意を使い回さないため。
    public static let currentVersion = 1
}

public extension Settings {

    /// **音声の送信先。旗印の唯一の分岐点。**
    ///
    /// 旗印は「デフォルト起動状態では、音声データを外部に一切送信しない」。
    /// それが成り立つ根拠は、**ここが nil を返す限り
    /// `.transcribe` が一度も許可されない**ことにある。
    ///
    /// ここ以外のどこでも `DataKind.audio` の送信先や
    /// `EgressPurpose.transcribe` の許可を作ってはいけない。
    /// `scripts/verify-privacy.sh` が grep で単一性を検査している。
    ///
    /// 5 条件の論理積。1 つでも欠ければ nil。
    ///
    /// > 留保: `config.json` を手で書けば同意も書ける。ただし docs/06 の脅威モデルは
    /// > 「守る相手は悪意ある攻撃者ではなく、自分たちの不注意」と宣言しているので、
    /// > そこは守備範囲外である。
    var cloudTranscriptionDestination: CloudTranscriptionDestination? {
        // 1. ネットワークのマスタースイッチ
        guard privacy.allowNetwork else { return nil }

        // 2. 認識エンジンとしてクラウドが選ばれている
        guard transcription.provider == CloudTranscriptionProviderID.openAIRealtime
        else { return nil }

        // 3. 送信先が書かれていて、ホストが取れる
        guard let url = URL(string: transcription.realtime.endpointURL),
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }

        // 4. **そのホストに対して**同意している。
        //    接続先を変えると自動的に失効する。
        guard privacy.audioEgress.consentedHost.lowercased() == host else { return nil }

        // 5. 同意したときの文面が現行版である
        guard privacy.audioEgress.noticeVersion == AudioEgressNotice.currentVersion
        else { return nil }

        let port = url.port ?? (url.scheme?.lowercased() == "ws" ? 80 : 443)
        return CloudTranscriptionDestination(
            host: host, port: port,
            providerID: CloudTranscriptionProviderID.openAIRealtime,
            operatorKind: transcription.realtime.operatorKind)
    }
}

/// `transcription.provider` に入る値。文字列リテラルを散らさない。
public enum CloudTranscriptionProviderID {
    public static let appleSpeechAnalyzer = "apple.speechanalyzer"
    public static let openAIRealtime = "openai.realtime"
}
