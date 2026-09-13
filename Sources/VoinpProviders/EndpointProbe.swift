import Foundation
import VoinpCore
import VoinpNet

/// ベース URL を正規化してモデル一覧を取る。
///
/// ユーザーは `https://host` とだけ入れることも、`/v1` まで入れることもある。
/// **黙って書き換えず、採用した URL を UI に出して確認させる。**
public struct EndpointProbe: Sendable {

    public struct Discovery: Sendable {
        public let normalizedBaseURL: URL
        public let models: [ModelInfo]
    }

    public enum Failure: Error, Sendable, Equatable {
        case invalidURL
        case blockedByGate
        case connectionRefused(host: String, port: Int)
        case hostNotFound(String)
        case tlsFailure(String)
        case timedOut
        case notFound(tried: [String])
        case unauthorized(hasKey: Bool)
        case notJSON(contentType: String?)
        case emptyModelList
        case server(status: Int)

        /// ユーザーに出す説明。原因ごとに具体的な次の一手を示す。
        public var message: String {
            switch self {
            case .invalidURL: "URL の形式が正しくありません。"
            case .blockedByGate: "プライバシー設定で送信が許可されていません。"
            case .connectionRefused(let h, let p):
                switch p {
                case 11434: "Ollama が起動していないようです（`ollama serve`）。"
                case 1234: "LM Studio の Local Server が起動していません。"
                default: "\(h):\(p) に接続できません。"
                }
            case .hostNotFound(let h): "ホスト \(h) が見つかりません。"
            case .tlsFailure: "サーバー証明書を検証できません。社内 CA を使用している場合は System キーチェーンに追加してください。"
            case .timedOut: "応答がありません。URL とネットワークを確認してください。"
            case .notFound: "このURLは OpenAI 互換 API ではないようです。`/v1` を含む URL を確認してください。"
            case .unauthorized(let hasKey):
                hasKey ? "API キーが受け付けられませんでした。" : "API キーが必要です。"
            case .notJSON(let type):
                type?.contains("text/html") == true
                    ? "Web UI の URL ではありませんか？ API の URL が必要です。"
                    : "JSON が返ってきませんでした。"
            case .emptyModelList: "利用できるモデルがありません。"
            case .server(let s): "サーバーがエラーを返しました（HTTP \(s)）。"
            }
        }
    }

    private let gate: EgressGate

    public init(gate: EgressGate) { self.gate = gate }

    public func discover(rawInput: String, credential: CredentialRef?) async -> Result<Discovery, Failure> {
        guard let base = Self.normalize(rawInput) else { return .failure(.invalidURL) }

        var tried: [String] = []
        var lastFailure: Failure = .notFound(tried: [])

        for candidate in Self.candidates(for: base) {
            tried.append(candidate.absoluteString)
            switch await fetchModels(at: candidate, credential: credential) {
            case .success(let models) where models.isEmpty:
                return .failure(.emptyModelList)
            case .success(let models):
                // /models を除いたものを保存する。
                let normalized = candidate.deletingLastPathComponent()
                return .success(Discovery(normalizedBaseURL: Self.trimSlash(normalized),
                                          models: models))
            case .failure(let f):
                // 認証エラーは候補を変えても直らないので即返す。
                if case .unauthorized = f { return .failure(f) }
                if case .tlsFailure = f { return .failure(f) }
                lastFailure = f
            }
        }
        if case .notFound = lastFailure { return .failure(.notFound(tried: tried)) }
        return .failure(lastFailure)
    }

    private func fetchModels(at url: URL, credential: CredentialRef?) async -> Result<[ModelInfo], Failure> {
        let request = EgressRequest(
            purpose: .modelDiscovery, providerID: "openai-compatible", url: url,
            headers: ["Accept": "application/json"],
            secretRefs: credential.map { ["Authorization": $0] } ?? [:],
            timeout: .seconds(5), carriesUserContent: false)

        do {
            let response = try await gate.send(request)
            switch response.status {
            case 200..<300:
                guard let models = Self.parseModels(response.body) else {
                    return .failure(.notJSON(contentType: nil))
                }
                return .success(models)
            case 401, 403:
                return .failure(.unauthorized(hasKey: credential != nil))
            case 404:
                return .failure(.notFound(tried: [url.absoluteString]))
            default:
                return .failure(.server(status: response.status))
            }
        } catch let e as VoinpError {
            if case .egressDenied = e { return .failure(.blockedByGate) }
            return .failure(.timedOut)
        } catch {
            return .failure(Self.classify(error, url: url))
        }
    }

    static func classify(_ error: any Error, url: URL) -> Failure {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return .connectionRefused(host: url.host ?? "?",
                                      port: url.port ?? (url.scheme == "https" ? 443 : 80))
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .hostNotFound(url.host ?? "?")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot:
            return .tlsFailure(ns.localizedDescription)
        case NSURLErrorTimedOut:
            return .timedOut
        default:
            return .timedOut
        }
    }

    // MARK: - URL の正規化

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }

        if !s.contains("://") {
            // スキームが無い場合、公開ホストを黙って平文に落とさない。
            let host = s.split(separator: "/").first.map(String.init) ?? s
            let bare = host.split(separator: ":").first.map(String.init) ?? host
            let isLocal = bare == "localhost" || bare.hasSuffix(".local")
                || HostClassifier.classifyLiteral(bare).map { $0 <= .privateNetwork } == true
            s = (isLocal ? "http://" : "https://") + s
        }
        return URL(string: s)
    }

    /// 試す順。ユーザーが `/v1` を付けている場合と付けていない場合の両方を見る。
    static func candidates(for base: URL) -> [URL] {
        if base.lastPathComponent == "models" { return [base] }
        return [base.appending(path: "models"), base.appending(path: "v1/models")]
    }

    static func trimSlash(_ url: URL) -> URL {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) ?? url
    }

    // MARK: - 応答の解釈（形の違いに寛容に）

    static func parseModels(_ data: Data) -> [ModelInfo]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let entries: [[String: Any]]
        if let dict = json as? [String: Any], let list = dict["data"] as? [[String: Any]] {
            entries = list                                    // OpenAI 形
        } else if let list = json as? [[String: Any]] {
            entries = list                                    // 裸の配列
        } else if let dict = json as? [String: Any], let list = dict["models"] as? [[String: Any]] {
            entries = list                                    // Ollama /api/tags
        } else {
            return nil
        }

        return entries.compactMap { entry in
            guard let id = (entry["id"] as? String) ?? (entry["name"] as? String),
                  !id.isEmpty else { return nil }
            // llama.cpp は gguf のファイルパスを返すので、表示だけ短くする。
            let display = id.contains("/") && id.hasSuffix(".gguf")
                ? (id as NSString).lastPathComponent : id
            return ModelInfo(id: id, displayName: display)
        }
    }
}
