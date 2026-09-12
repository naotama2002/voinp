import OSLog

/// アプリ全体のログ。
///
/// **ユーザーのテキストは必ず `privacy: .private` で補間すること。**
/// `os.log` の既定は `.public` なので、素で書くと書き起こしが unified log に入り、
/// 任意の管理ツールから読めてしまう。旗印を丸ごと破る現実的な経路の 1 つ。
public enum Log {
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let insert = Logger(subsystem: subsystem, category: "insert")
    public static let config = Logger(subsystem: subsystem, category: "config")
    public static let net = Logger(subsystem: subsystem, category: "net")
    public static let refine = Logger(subsystem: subsystem, category: "refine")

    public static let subsystem = "com.naotama2002.voinp"
}
