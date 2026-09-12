import Foundation
import VoinpCore

/// `~/Library/Application Support/voinp/config.json` の読み書き。
///
/// 壊れた設定でも**絶対にリセットしない**。ユーザーはこのファイルを調整している。
/// 読めなければメモリ上の既定値で動き、目に見えるエラー状態に入る
/// （その間、送信ゲートは全拒否になる = fail closed）。
public struct ConfigStore: Sendable {

    public struct Loaded: Sendable {
        public let settings: Settings
        /// 読めなかった理由。nil なら正常。
        public let error: String?
        public var hasError: Bool { error != nil }
    }

    public let directory: URL
    public var configURL: URL { directory.appending(path: "config.json") }
    public var promptsURL: URL { directory.appending(path: "prompts") }

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/voinp")
    }

    public func load() -> Loaded {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return Loaded(settings: Settings(), error: nil)   // 初回起動
        }
        do {
            let data = try Data(contentsOf: configURL)
            let settings = try Settings.decode(data)
            guard settings.schemaVersion <= Settings.currentSchemaVersion else {
                // 未来のバージョンで書かれたファイル。**触らない。**
                return Loaded(settings: Settings(),
                              error: "設定ファイルがこのバージョンより新しい形式です（v\(settings.schemaVersion)）")
            }
            return Loaded(settings: settings, error: nil)
        } catch let e as DecodingError {
            return Loaded(settings: Settings(), error: Self.describe(e))
        } catch {
            return Loaded(settings: Settings(), error: "設定ファイルを読めません: \(error.localizedDescription)")
        }
    }

    /// 同じディレクトリの一時ファイルに書いてから rename する。
    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tmp = directory.appending(path: "config.json.tmp")
        try settings.encoded().write(to: tmp, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
    }

    private static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, _):       "設定の項目が不正です: \(k.stringValue)"
        case .typeMismatch(let t, let c):  "型が違います: \(c.codingPath.map(\.stringValue).joined(separator: ".")) は \(t) であるべきです"
        case .valueNotFound(_, let c):     "値がありません: \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let c):        "JSON として解釈できません: \(c.debugDescription)"
        @unknown default:                  "設定ファイルを解釈できません"
        }
    }
}
