import Foundation
import VoinpCore

/// 秘密をヘッダにどう載せるか。**値そのものはここに入らない（参照だけ）。**
///
/// かつては `Bearer ` を常に前置していた。そのため Azure OpenAI の
/// `api-key: <生キー>` が表現できず、呼び出し側が自分でヘッダを組む
/// ＝ 秘密を `String` で持つ、という逃げ方しか無かった。
/// 置き方を型にすれば、「秘密はゲートの中で初めて値になる」性質を保ったまま方式を増やせる。
public struct SecretInjection: Sendable, Hashable {
    public enum Scheme: Sendable, Hashable {
        /// `Authorization: Bearer <secret>`（OpenAI ほか）
        case bearer
        /// `api-key: <secret>`（Azure OpenAI）。前置きなしの生値。
        case raw
    }

    public let ref: CredentialRef
    public let scheme: Scheme

    public init(ref: CredentialRef, scheme: Scheme) {
        self.ref = ref
        self.scheme = scheme
    }

    public static func bearer(_ ref: CredentialRef) -> Self { .init(ref: ref, scheme: .bearer) }
    public static func raw(_ ref: CredentialRef) -> Self { .init(ref: ref, scheme: .raw) }

    /// ヘッダに載せる文字列。**この関数だけが前置きを知っている。**
    func headerValue(for secret: String) -> String {
        switch scheme {
        case .bearer: "Bearer \(secret)"
        case .raw: secret
        }
    }
}

public struct EgressRequest: Sendable {
    public let purpose: EgressPurpose
    public let providerID: String
    public let url: URL
    public let method: String
    public let headers: [String: String]
    /// 秘密は参照で渡し、ゲートの内部で解決する。呼び出し側が値を持たない。
    public let secretRefs: [String: SecretInjection]
    public let body: Data?
    public let timeout: Duration
    /// 音声や書き起こしを含むか。監査とポリシー判定に使う。
    public let carriesUserContent: Bool

    public init(purpose: EgressPurpose, providerID: String, url: URL,
                method: String = "GET", headers: [String: String] = [:],
                secretRefs: [String: SecretInjection] = [:], body: Data? = nil,
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
    /// システムのプロキシ設定を引く。テストから差し替えられるよう closure にしてある
    /// （本物は実機のシステム設定に依存し、CI で経路を再現できない）。
    private let proxyRoute: @Sendable (URL) async -> ProxyResolver.Route
    private let session: URLSession
    /// 長寿命のストリーム専用。理由は init の中のコメント。
    private let streamSession: URLSession
    private let audit: EgressAuditLog

    public init(policy: @escaping @Sendable () async -> EgressPolicySnapshot,
                credentials: any CredentialStore,
                audit: EgressAuditLog = EgressAuditLog(),
                proxyRoute: @escaping @Sendable (URL) async -> ProxyResolver.Route
                    = { await ProxyResolver().route(for: $0) }) {
        self.policy = policy
        self.credentials = credentials
        self.classifier = HostClassifier()
        self.proxyRoute = proxyRoute
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

        // **ストリーム専用にもう 1 本持つ。**
        // 上の session は httpMaximumConnectionsPerHost = 1 なので、
        // 長寿命の WebSocket が同一ホストの 1 本を占有すると、
        // 校正リクエストが裏で永久に待つことになる。
        let streamConfig = URLSessionConfiguration.ephemeral
        streamConfig.waitsForConnectivity = false
        streamConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        streamConfig.urlCache = nil
        streamConfig.httpCookieStorage = nil
        streamConfig.httpShouldSetCookies = false
        self.streamSession = URLSession(configuration: streamConfig,
                                        delegate: RedirectRefusingDelegate(),
                                        delegateQueue: nil)
    }

    /// 音声などを流し続けるための双方向ストリームを開く。
    ///
    /// **判定は `send()` と完全に同じ `authorize` を通る。**
    /// 違うのは I/O の形だけで、マスタースイッチもホスト許可も用途も
    /// 到達範囲もプロキシもスキームも、1 つも省略していない。
    ///
    /// 監査は「接続時 1 件 + 切断時 1 件」。フレームごとには記録しない
    /// （記録するとリングバッファが一掃されて過去の拒否記録が消える）。
    public func connect(_ request: EgressRequest) async throws -> any EgressWebSocketChannel {
        let auth = try await authorize(request, transport: .stream)

        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = Double(request.timeout.components.seconds)
        for (k, v) in request.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }
        urlRequest = Self.applyingSecrets(to: urlRequest, request.secretRefs, using: credentials)

        let started = ContinuousClock.now
        let task = streamSession.webSocketTask(with: urlRequest)
        task.resume()
        await audit.record(.streamOpened(host: auth.host, purpose: request.purpose,
                                         reach: auth.effectiveClass,
                                         handshake: ContinuousClock.now - started))

        return AuditedWebSocketChannel(
            inner: URLSessionWebSocketChannel(task: task),
            host: auth.host, purpose: request.purpose, reach: auth.effectiveClass,
            openedAt: started, audit: audit)
    }

    /// 判定 1〜6 を通った証拠。
    ///
    /// **`authorize` の中でしか作れない**（イニシャライザが private）。
    /// 実 I/O を行うメソッドはこれを要求するので、判定を飛ばした送信経路は
    /// 書こうとしてもコンパイルできない。
    /// 「同じ 6 手順を気をつけて書き写す」ではなく、書けなくするのが狙い。
    struct Authorization: Sendable {
        let host: String
        /// max(宛先クラス, プロキシクラス)。監査にもこちらを残す。
        let effectiveClass: EgressClass

        private init(host: String, effectiveClass: EgressClass) {
            self.host = host
            self.effectiveClass = effectiveClass
        }

        fileprivate static func granted(host: String,
                                        effectiveClass: EgressClass) -> Authorization {
            Authorization(host: host, effectiveClass: effectiveClass)
        }
    }

    /// 送信の形。**スキームの取り違えを構造的に止めるために持つ。**
    /// `send(wss://)` も `connect(https://)` も判定の入口で落ちる。
    enum Transport: Sendable {
        case requestResponse   // http / https
        case stream            // ws / wss

        var allowedSchemes: Set<String> {
            switch self {
            case .requestResponse: ["http", "https"]
            case .stream: ["ws", "wss"]
            }
        }
    }

    public func send(_ request: EgressRequest) async throws -> EgressResponse {
        let auth = try await authorize(request, transport: .requestResponse)
        return try await perform(request, host: auth.host, reach: auth.effectiveClass)
    }

    /// **送信前の判定はここ 1 箇所だけ。**
    ///
    /// `send` も、これから足す WebSocket 経路も、必ずここを通る。
    /// 経路ごとに手順を書き写すと、片方だけ緩い実装が入り込む。
    private func authorize(_ request: EgressRequest,
                           transport: Transport) async throws -> Authorization {
        let snapshot = await policy()
        let host = request.url.host ?? ""

        // 0. スキームがこの送信形に合っているか。
        //    ws を data(for:) に渡す / https を webSocketTask に渡す、という
        //    取り違えをここで止める。手順 6 は「平文かどうか」しか見ないので別物。
        let scheme = request.url.scheme?.lowercased() ?? ""
        guard transport.allowedSchemes.contains(scheme) else {
            await audit.record(.denied(host: host, purpose: request.purpose,
                                       reason: .schemeNotAllowed(scheme)))
            throw VoinpError.egressDenied(.schemeNotAllowed(scheme))
        }

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

        // 5. プロキシ。**宛先の分類だけでは足りない。**
        //    システム設定や PAC でプロキシが入っていれば、実際の TCP 相手はプロキシ。
        //    宛先が 127.0.0.1 でも、公開プロキシが適用されれば本文は社外へ出る。
        //    「分類して記録する」ではなく、許可判定そのものに含める。
        let effective: EgressClass
        // **`wss` のまま聞かない。** `CFNetworkCopyProxiesForURL` と PAC の
        // `FindProxyForURL` はスキーム文字列を見るので、PAC が
        // `shExpMatch(url, "https:*")` のような分岐を持っていると
        // `wss` は当たらず「直結」と誤答されうる。
        // URLSession 自身がハンドシェイクを HTTP(S) として行う以上、
        // 聞くべきなのは写像後の URL のほう。写像できなければ拒否する。
        guard let probeURL = Self.proxyProbeURL(for: request.url) else {
            await audit.record(.denied(host: host, purpose: request.purpose,
                                       reason: .proxyChainUnknown))
            throw VoinpError.egressDenied(.proxyChainUnknown)
        }
        switch await proxyRoute(probeURL) {
        case .direct:
            effective = reach

        case .proxied(let proxyHosts):
            // プロキシ自身にも宛先と同じ基準を課す。
            var proxyClass = EgressClass.loopback
            for p in proxyHosts {
                proxyClass = max(proxyClass, try await classifier.classify(host: p))
            }
            guard proxyClass <= snapshot.maxClass else {
                await audit.record(.denied(host: host, purpose: request.purpose,
                                           reason: .proxyExceedsPolicy(proxyClass)))
                throw VoinpError.egressDenied(.proxyExceedsPolicy(proxyClass))
            }
            // ローカルの LLM を指しているのにプロキシへ出て行く構成は異常。
            // 「この Mac から出ない」という約束が黙って破れる典型なので、必ず止める。
            guard !(reach == .loopback && proxyClass > .loopback) else {
                await audit.record(.denied(host: host, purpose: request.purpose,
                                           reason: .loopbackDestinationWouldLeaveViaProxy))
                throw VoinpError.egressDenied(.loopbackDestinationWouldLeaveViaProxy)
            }
            // 実効クラスは遠いほうに合わせる。監査記録にもこちらを残す。
            effective = max(reach, proxyClass)

        case .needsPAC, .undeterminable:
            // PAC の評価失敗など。**「たぶん直結」で送らない。**
            await audit.record(.denied(host: host, purpose: request.purpose,
                                       reason: .proxyChainUnknown))
            throw VoinpError.egressDenied(.proxyChainUnknown)
        }

        // 6. スキーム。公開ホストへの平文は常に拒否する。
        //    プロキシ経由なら平文はプロキシまで丸見えなので、実効クラスで判定する。
        if Self.isPlaintext(request.url.scheme), effective > .privateNetwork {
            await audit.record(.denied(host: host, purpose: request.purpose,
                                       reason: .insecureSchemeForClass(effective)))
            throw VoinpError.egressDenied(.insecureSchemeForClass(effective))
        }

        return .granted(host: host, effectiveClass: effective)
    }

    /// TLS の無いスキームか。
    ///
    /// **等値比較で書かないこと。** `Foundation` は URL のスキームを小文字化しない:
    ///
    ///     URL(string: "HTTP://example.com")?.scheme   // => "HTTP"
    ///
    /// かつては `request.url.scheme == "http"` と書いていたため、設定に大文字で
    /// `HTTP://` と入れるとこの判定をすり抜けた。`EndpointProbe.normalize` は
    /// `://` を含む入力をそのまま通すので、実際に到達する経路がある。
    /// `URLSession` は `HTTP://` を問題なく http として扱うので、
    /// **公開ホストへ書き起こしテキストが平文で出ていた。**
    ///
    /// `ws` を含めているのは、WebSocket の平文経路が http と同じ危険度だから。
    /// ここに足し忘れると、音声がプロキシに丸見えのまま流れる。
    static func isPlaintext(_ scheme: String?) -> Bool {
        switch scheme?.lowercased() {
        case "http", "ws": true
        default: false
        }
    }

    /// プロキシ問い合わせ用に `ws` / `wss` を `http` / `https` へ写像する。
    ///
    /// host / port / path / query はそのまま保つ。写像できなければ `nil` を返し、
    /// 呼び出し側は「判定不能」として拒否する（直結とみなさない）。
    static func proxyProbeURL(for url: URL) -> URL? {
        let scheme = url.scheme?.lowercased()
        let mapped: String? = switch scheme {
        case "ws": "http"
        case "wss": "https"
        case "http", "https": scheme
        default: nil
        }
        guard let mapped else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = mapped
        return components.url
    }

    /// 秘密を解決してヘッダに載せる。
    ///
    /// **空 / 未登録なら載せない。** これは接続先ごとに口座を分けている性質
    /// （`CredentialRef.openAICompatible(host:)`）と対になっていて、
    /// 未登録のホストへ前のサーバーの API キーが飛ぶのを防ぐ。
    ///
    /// `perform`（HTTP）と `connect`（WebSocket ハンドシェイク）の両方から呼ぶ。
    /// WebSocket の認証もハンドシェイクの HTTP ヘッダなので、同じ関数で足りる。
    static func applyingSecrets(to base: URLRequest,
                                _ injections: [String: SecretInjection],
                                using store: any CredentialStore) -> URLRequest {
        var request = base
        for (header, injection) in injections {
            guard let secret = try? store.read(injection.ref), !secret.isEmpty else { continue }
            request.setValue(injection.headerValue(for: secret), forHTTPHeaderField: header)
        }
        return request
    }

    private func perform(_ request: EgressRequest, host: String, reach: EgressClass) async throws -> EgressResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = Double(request.timeout.components.seconds)
        for (k, v) in request.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }

        urlRequest = Self.applyingSecrets(to: urlRequest, request.secretRefs, using: credentials)

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
