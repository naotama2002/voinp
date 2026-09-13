import Foundation

/// プリセットの読み込みと保存。
///
/// 組み込みは `.app` 内に持ち、**ディスクには展開しない**。
/// ユーザーが編集したものだけが `prompts/` に置かれるので、
/// 「自分が何を変えたか」が一目で分かり、更新時に衝突もしない。
/// 同じ id のファイルがあれば組み込みを上書きする。
public struct PromptLibrary: Sendable {

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/voinp/prompts")
    }

    /// 組み込み + ユーザー定義。同じ id はユーザー側が勝つ。
    public func load() -> [Preset] {
        var byID: [String: Preset] = [:]
        for p in Preset.builtins { byID[p.id] = p }
        for p in loadUserPresets() { byID[p.id] = p }
        return byID.values.sorted { a, b in
            a.order == b.order ? a.id < b.id : a.order < b.order
        }
    }

    public func preset(id: String) -> Preset {
        load().first { $0.id == id } ?? Preset.builtin(id: id)
    }

    /// 編集内容を保存する。組み込みと同じ id なら上書きとして機能する。
    public func save(_ preset: Preset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(preset.id).md")
        try Self.serialize(preset).write(to: url, atomically: true, encoding: .utf8)
    }

    /// ユーザー定義を削除して組み込みに戻す。
    public func resetToBuiltin(id: String) throws {
        let url = directory.appending(path: "\(id).md")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func isCustomized(id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: "\(id).md").path)
    }

    // MARK: - ファイル形式

    private func loadUserPresets() -> [Preset] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Self.parse(text, defaultID: url.deletingPathExtension().lastPathComponent)
            }
    }

    /// front-matter 付き Markdown。
    /// YAML の依存を足さずに済むよう、フラットな `key: value` だけを読む。
    static func parse(_ text: String, defaultID: String) -> Preset? {
        var id: String = defaultID
        var name: String = defaultID
        var order: Int = 50
        var body: String = text
        var policy: GuardPolicy = GuardPolicy()
        var temperature: Double = 0.1
        var skipsLLM: Bool = false

        if text.hasPrefix("---") {
            let parts = text.components(separatedBy: "---")
            if parts.count >= 3 {
                let front = parts[1]
                body = parts.dropFirst(2).joined(separator: "---")
                for line in front.split(separator: "\n") {
                    let kv = line.split(separator: ":", maxSplits: 1).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    guard kv.count == 2 else { continue }
                    switch kv[0] {
                    case "id": id = kv[1]
                    case "name": name = kv[1]
                    case "order": order = Int(kv[1]) ?? order
                    case "skipsLLM": skipsLLM = kv[1] == "true"
                    case "temperature": temperature = Double(kv[1]) ?? temperature
                    case "lengthRatioMin":
                        if let v = Double(kv[1]) { policy.lengthRatio = v...policy.lengthRatio.upperBound }
                    case "lengthRatioMax":
                        if let v = Double(kv[1]) { policy.lengthRatio = policy.lengthRatio.lowerBound...v }
                    case "requireSameScript": policy.requireSameScript = kv[1] == "true"
                    case "allowMarkdown": policy.allowMarkdown = kv[1] == "true"
                    case "enforceNumbers": policy.enforceNumbers = kv[1] == "true"
                    case "enforceQuestionShape": policy.enforceQuestionShape = kv[1] == "true"
                    case "contentRetention":
                        policy.contentRetention = kv[1] == "none" ? nil : Double(kv[1])
                    default: break
                    }
                }
            }
        }

        return Preset(id: id, name: name, order: order,
                      body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                      baseOverride: nil, skipsLLM: skipsLLM,
                      guardPolicy: policy, temperature: temperature)
    }

    static func serialize(_ p: Preset) -> String {
        // front-matter は行ごとに組み立てる。
        // 複数行リテラルの中に "---" を置くと区切りとして扱われて壊れる。
        var lines: [String] = ["---"]
        lines.append("id: \(p.id)")
        lines.append("name: \(p.name)")
        lines.append("order: \(p.order)")
        lines.append("temperature: \(p.temperature)")
        lines.append("lengthRatioMin: \(p.guardPolicy.lengthRatio.lowerBound)")
        lines.append("lengthRatioMax: \(p.guardPolicy.lengthRatio.upperBound)")
        lines.append("requireSameScript: \(p.guardPolicy.requireSameScript)")
        lines.append("allowMarkdown: \(p.guardPolicy.allowMarkdown)")
        lines.append("enforceNumbers: \(p.guardPolicy.enforceNumbers)")
        lines.append("enforceQuestionShape: \(p.guardPolicy.enforceQuestionShape)")
        lines.append("contentRetention: \(p.guardPolicy.contentRetention.map { "\($0)" } ?? "none")")
        lines.append("---")
        lines.append(p.body)
        return lines.joined(separator: "\n")
    }
}
