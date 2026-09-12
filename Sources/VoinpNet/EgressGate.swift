import Foundation
import VoinpCore

public struct EgressRequest: Sendable {
    public let purpose: EgressPurpose
    public let providerID: String
    public let url: URL
    public let method: String
    public let headers: [String: String]
    /// 秘密は参照で渡し、ゲートの内部で解決する。呼び出し側が値を持たない。
    public let secretRefs: [String: CredentialRef]
    public let body: Data?
    public let timeout: Duration
    /// 音声や書き起こしを含むか。監査とポリシー判定に使う。
    public let carriesUserContent: Bool

    public init(purpose: EgressPurpose, providerID: String, url: URL,
                method: String = "GET", headers: [String: String] = [:],
                secretRefs: [String: CredentialRef] = [:], body: Data? = nil,
                timeout: Duration = .seconds(8), carriesUserContent: Bool = false) {
        self.purpose = purpose; self.providerID = providerID; self.url = url
        self.method = method; self.headers = headers; self.secretRefs = secretRefs
        self.body = body; self.timeout = timeout; self.carriesUserContent = carriesUserContent
    }
}

public struct EgressResponse: Sendable {
    public let status: Int
    public let body: Data
}

/// **アプリ内で唯一 URLSession を持つ場所。**
///
/// 送信前にポリシーを評価し、通らないものは投げる前に拒否する。
/// 判定は「設定から導出した許可ホスト」と「解決後アドレスの到達範囲」だけで行い、
/// 運用主体の申告（self-hosted かどうか）は**一切参照しない**。
public actor EgressGate {

    private let policy: @Sendable () async -> EgressPolicySnapshot
    private let credentials: any CredentialStore
    private let classifier: HostClassifier
    private let session: URLSession
    private let audit: EgressAuditLog

    public init(policy: @escaping @Sendable () async -> EgressPolicySnapshot,
                credentials: any CredentialStore,
                audit: EgressAuditLog = EgressAuditLog()) {
        self.policy = policy
        self.credentials = credentials
        self.classifier = HostClassifier()
        self.audit = audit

        let config = URLSessionConfiguration.ephemeral
        // 既定の true だと、相手が落ちているとき無言でハングする。
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // レスポンス本文は書き起こしテキストそのもの。ディスクに残さない。
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config,
                                  delegate: RedirectRefusingDelegate(),
                                  delegateQueue: nil)
    }

    public func send(_ request: EgressRequest) async throws -> EgressResponse {
        let snapshot = await policy()
        let host = request.url.host ?? ""

        // 1. マスタースイッチ。設定が壊れていれば denyAll が来るので fail closed。
        guard snapshot.masterAllow else {
            await audit.record(.denied(host: host, purpose: request.purpose, reason: .networkDisabled))
            throw VoinpError.egressDenied(.networkDisabled)
        }

        // 2. 許可ホスト。設定から導出されたものと、短命の探索候補のみ。
        guard snapshot.allows(host: host, purpose: request.purpose, at: .now) else {
            await audit.record(.denied(host: host, purpose: request.purpose,
                                       reason: .hostNotAllowed(host)))
            throw VoinpError.egressDenied(.hostNotAllowed(host))
        }

        // 3. 用途。
        guard snapshot.allowedPurposes.contains(request.purpose) else {
            await audit.record(.denied(host: host, purpose: request.purpose,
                                       reason: .purposeNotAllowed(request.purpose.rawValue)))
            throw VoinpError.egressDenied(.purposeNotAllowed(request.purpose.rawValue))
        }

        // 4. 到達範囲。解決後アドレスで判定する。
        let reach = try await classifier.classify(host: host)
        guard reach <= snapshot.maxClass else {
            await audit.record(.denied(host: host, purpose: request.purpose,
                                       reason: .classExceedsPolicy(requested: reach, max: snapshot.maxClass)))
            throw VoinpError.egressDenied(.classExceedsPolicy(requested: reach, max: snapshot.maxClass))
        }

        // 5. スキーム。公開ホストへの平文は常に拒否する。
        if request.url.scheme == "http", reach > .privateNetwork {
            await audit.record(.denied(host: host, purpose: request.purpose,
                                       reason: .insecureSchemeForClass(reach)))
            throw VoinpError.egressDenied(.insecureSchemeForClass(reach))
        }

        return try await perform(request, host: host, reach: reach)
    }

    private func perform(_ request: EgressRequest, host: String, reach: EgressClass) async throws -> EgressResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = Double(request.timeout.components.seconds)
        for (k, v) in request.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }

        // 秘密はここで初めて値になる。呼び出し側は参照しか持たない。
        for (header, ref) in request.secretRefs {
            if let secret = try? credentials.read(ref), !secret.isEmpty {
                urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: header)
            }
        }

        let started = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            await audit.record(.allowed(host: host, purpose: request.purpose, status: status,
                                        reach: reach, bytesOut: request.body?.count ?? 0,
                                        bytesIn: data.count,
                                        duration: ContinuousClock.now - started))
            return EgressResponse(status: status, body: data)
        } catch {
            await audit.record(.failed(host: host, purpose: request.purpose,
                                       reason: (error as NSError).code))
            throw error
        }
    }
}

/// リダイレクトは**レビューされていない送信先の変更**なので追従しない。
private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
