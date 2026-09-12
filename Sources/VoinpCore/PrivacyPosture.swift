import Foundation

/// 現在の設定から導出される「何がどこへ出るか」。
///
/// **2 つの軸を混同しないこと。**
/// - 到達範囲 (`EgressClass`) … 解決後アドレスから機械的に判定できる。**強制に使う唯一の軸**
/// - 運用主体 (`OperatorKind`) … 検証不能な宣言。**表示にしか使わない。許可を広げない**
///
/// 自社運用の LLM が `https://llm.example.co.jp` にある場合、
/// 到達範囲は `.publicInternet` だが運用主体は `.selfHosted` である。
/// 逆に `api.openai.com` は両方とも外部。この 2 つは独立している。
public struct PrivacyPosture: Equatable, Sendable {

    /// メニューバーのアイコンはこれで決める。**検証可能な到達範囲のみ**に基づく。
    /// 宣言でアイコンが優しくなってはいけない。
    public enum Level: Int, Comparable, Sendable {
        case offline = 0        // 到達できる送信先がない
        case loopbackOnly = 1   // この Mac の中だけ。文字通り外に出ない
        case localNetwork = 2   // Mac の外に出るが LAN 内
        case external = 3       // この Mac とネットワークの外へ出る
        case misconfigured = 4  // 設定エラー。通信を停止している

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// 誰が運用している先か。**ユーザーの申告であり、アプリは検証できない。**
    public enum OperatorKind: String, Codable, Sendable {
        case selfHosted   // 自社・自分で運用しているサーバ
        case vendor       // 外部サービス
        case unknown
    }

    public enum DataKind: String, Sendable {
        case audio, transcript, refinedText
    }

    public struct Destination: Equatable, Sendable {
        public let dataKind: DataKind
        public let host: String
        public let port: Int
        public let reach: EgressClass
        /// 宣言。表示のみに使う。
        public let operatorKind: OperatorKind
        public let providerID: String
        public let viaProxy: String?

        public init(dataKind: DataKind, host: String, port: Int, reach: EgressClass,
                    operatorKind: OperatorKind, providerID: String, viaProxy: String? = nil) {
            self.dataKind = dataKind; self.host = host; self.port = port
            self.reach = reach; self.operatorKind = operatorKind
            self.providerID = providerID; self.viaProxy = viaProxy
        }
    }

    public let level: Level
    public let destinations: [Destination]

    public init(level: Level, destinations: [Destination]) {
        self.level = level
        self.destinations = destinations
    }

    public static let offline = PrivacyPosture(level: .offline, destinations: [])

    /// **音声が Mac の外に出るか。** 旗印そのもの。
    /// 整形テキストの送信先が増えてもここは false のままでなければならない。
    public var audioLeavesMachine: Bool {
        destinations.contains { $0.dataKind == .audio && $0.reach > .loopback }
    }
}
