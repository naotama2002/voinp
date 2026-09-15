import AVFoundation
import Foundation
import VoinpCore
import VoinpEngine
import VoinpNet

/// `gpt-live-transcribe` の実機確認。`--probe-transcribe`
///
/// **設計の分岐点を実測で潰すための道具。** 判断できていないのは:
/// - `rate: 16000` が受理されるか（通れば退避時のフォーマット問題が消える）
/// - `languages` と `keywords` が日本語で実際に効くか
/// - `delay` の各段での精度と遅延
/// - 社内 PAC 経由で `wss` が通るか
///
/// **API キーは値として受け取らない。** 環境変数名か Keychain の口座名だけを受け、
/// 実際の解決は `EgressGate` の中で行う。この道具はヘッダを組み立てず、出力もしない。
enum RealtimeProbe {

    struct Options {
        var baseURL = ""
        var model = ""
        var useKeychain = false
        /// 鍵を置いた環境変数の名前。**値ではなく名前だけを持つ。**
        var keyEnvName: String?
        var wavPath: String?
        var languages: [String] = ["ja", "en"]
        var keywords: [String] = []
        var delay = "low"
        var rates: [Int] = [16_000, 24_000]
        var compareWithApple = true
    }

    // MARK: - 入口

    static func run(_ options: Options) async {
        guard let base = URL(string: options.baseURL), let host = base.host else {
            print("❌ URL を解釈できません: \(options.baseURL)")
            return
        }

        print("接続先: \(host)")
        let reach = (try? await HostClassifier().classify(host: host))
        print("到達範囲: \(reach.map { "\($0)" } ?? "判定不可")")

        // **PAC の答えを先に見る。** wss をそのまま聞いた場合と、
        // https に写像して聞いた場合で答えが変わるかを確かめたい。
        // **PAC は URL のスキーム文字列で分岐する。** wss のまま聞いた答えと、
        // https へ写像して聞いた答えが食い違うなら、写像が必須だと分かる。
        for candidate in Self.candidates(from: base) {
            print("経路: \(candidate.absoluteString)")
            let raw = await ProxyResolver().route(for: candidate)
            print("   wss のまま     → \(describe(raw))")
            if let mappedURL = EgressGate.proxyProbeURL(for: candidate) {
                let mapped = await ProxyResolver().route(for: mappedURL)
                print("   https へ写像後 → \(describe(mapped))")
            } else {
                print("   https へ写像後 → 写像できず")
            }
        }

        if let env = options.keyEnvName {
            print("鍵: 環境変数 \(env)  ヘッダ: \(authHeader(for: host))")
        } else {
            print("鍵: Keychain \(CredentialRef.service) / probe@\(host.lowercased())"
                  + "  ヘッダ: \(authHeader(for: host))")
            print("  未登録なら: security add-generic-password -s \(CredentialRef.service)"
                  + " -a probe@\(host.lowercased()) -w")
        }

        guard let credential = resolveCredentialRef(options, host: host) else {
            print("❌ API キーの置き場所が指定されていません（--key-env か --keychain）")
            return
        }

        // 音声を用意する（rate ごとに変換する必要があるので、元データだけ持つ）
        var source: AudioSource?
        if let path = options.wavPath {
            guard let loaded = AudioSource.load(path: path) else {
                print("❌ WAV を読めません: \(path)")
                return
            }
            source = loaded
            print("\n音声: \(path) (\(String(format: "%.1f", loaded.duration)) 秒)")
        }

        // rate ごとに試す
        for rate in options.rates {
            print("\n=== rate \(rate) ===")
            await probeOnce(options: options, base: base, host: host,
                            credential: credential, rate: rate, source: source)
        }

        if options.compareWithApple, let source {
            print("\n=== macOS SpeechAnalyzer（対照） ===")
            await transcribeWithApple(source)
        }
    }

    // MARK: - 1 回分の接続

    private static func probeOnce(options: Options, base: URL, host: String,
                                  credential: CredentialRef, rate: Int,
                                  source: AudioSource?) async {
        let snapshot = EgressPolicySnapshot(
            masterAllow: true, maxClass: .publicInternet,
            allowedHosts: [host], allowedPurposes: [.transcribe], probeCandidate: nil)
        let gate = EgressGate(policy: { snapshot }, credentials: store(options))

        for url in Self.candidates(from: base) {
            let started = ContinuousClock.now
            let request = EgressRequest(
                purpose: .transcribe, providerID: "gpt-live-transcribe", url: url,
                headers: [:],   // OpenAI-Beta: realtime=v1 は GA で廃止済み
                secretRefs: [Self.authHeader(for: host): Self.injection(for: host, credential)],
                timeout: .seconds(10), carriesUserContent: true)

            let channel: any EgressWebSocketChannel
            do {
                channel = try await gate.connect(request)
            } catch {
                print("  ✗ \(url.absoluteString)")
                print("     \(shortReason(error))")
                continue
            }

            // **必ず終わらせる。** `URLSessionWebSocketTask.receive()` は
            // Swift の Task キャンセルを見ないので、時間で打ち切るには
            // close() して待ちを解くしかない（自分で踏んだ）。
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(source == nil ? 6 : 30))
                await channel.close()
            }
            let outcome = await configureAndRun(
                channel: channel, options: options, rate: rate, source: source,
                connectedAt: started)
            watchdog.cancel()
            await channel.close()

            switch outcome {
            case .rejected(let message):
                print("  ✗ \(url.absoluteString)")
                print("     セッション設定を拒否: \(message)")
            case .ok(let handshakeMs, let text, let firstDeltaMs):
                print("  ✅ \(url.absoluteString)")
                print("     ハンドシェイク: \(handshakeMs) ms")
                if let firstDeltaMs { print("     最初の delta まで: \(firstDeltaMs) ms") }
                if !text.isEmpty { print("     結果: \(text)") }
                return   // 通る候補が見つかったら以降は試さない
            case .disconnected(let why):
                print("  ✗ \(url.absoluteString)")
                print("     \(why)")
            }
        }
    }

    private enum Outcome {
        case ok(handshakeMs: Int, text: String, firstDeltaMs: Int?)
        case rejected(String)
        /// 切れた理由をそのまま持つ。「応答なし」だけでは切り分けられない。
        case disconnected(String)
    }

    private static func configureAndRun(channel: any EgressWebSocketChannel,
                                        options: Options, rate: Int,
                                        source: AudioSource?,
                                        connectedAt: ContinuousClock.Instant) async -> Outcome {
        do {
            try await channel.send(sessionUpdate(options: options, rate: rate))
        } catch {
            return .disconnected(describeTransport(error))
        }

        var handshakeMs: Int?
        var firstDeltaMs: Int?
        var pending: [String: String] = [:]
        var finalized: [String] = []
        var sentAudio = false

        // 受信ループ。session.updated を受けたら音声を流し始める。
        for _ in 0..<2_000 {
            let data: Data
            do {
                data = try await channel.receive()
            } catch {
                // ハンドシェイクが 101 以外だとここに来る。認証失敗もここ。
                if handshakeMs == nil {
                    return .disconnected(describeTransport(error))
                }
                break
            }
            guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "session.updated", "transcription_session.updated":
                handshakeMs = ms(since: connectedAt)
                guard let source, !sentAudio else { break }
                sentAudio = true
                await stream(source: source, rate: rate, to: channel)

            case "error":
                let message = ((event["error"] as? [String: Any])?["message"] as? String)
                    ?? "詳細不明"
                return .rejected(message)

            case "conversation.item.input_audio_transcription.delta":
                if firstDeltaMs == nil { firstDeltaMs = ms(since: connectedAt) }
                let id = event["item_id"] as? String ?? "-"
                pending[id, default: ""] += (event["delta"] as? String ?? "")

            case "conversation.item.input_audio_transcription.completed":
                let id = event["item_id"] as? String ?? "-"
                pending[id] = nil
                if let t = event["transcript"] as? String, !t.isEmpty { finalized.append(t) }

            default:
                break
            }

            // 音声を送り切っていて、確定が出たら終わり
            if sentAudio, !finalized.isEmpty, pending.isEmpty { break }
            // 音声を渡されていないなら、設定が通ったことを確かめた時点で十分
            if source == nil, handshakeMs != nil { break }
        }

        guard let handshakeMs else { return .disconnected("session.updated が来ませんでした") }
        let text = (finalized + pending.values.sorted()).joined()
        return .ok(handshakeMs: handshakeMs, text: text, firstDeltaMs: firstDeltaMs)
    }

    // MARK: - 送るもの

    /// `session.update`。**構造はドキュメントどおり。**
    /// `keywords` に `<` `>` が入ると設定全体が拒否されるので落とす（参考実装の知見）。
    static func sessionUpdate(options: Options, rate: Int) -> Data {
        var transcription: [String: Any] = [
            "model": options.model,
            "languages": options.languages,
            "delay": options.delay,
        ]
        let safeKeywords = options.keywords
            .filter { !$0.contains("<") && !$0.contains(">") }
            .prefix(64)
        if !safeKeywords.isEmpty { transcription["keywords"] = Array(safeKeywords) }

        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": rate],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// 100ms フレームで送る。終わったら commit。
    private static func stream(source: AudioSource, rate: Int,
                               to channel: any EgressWebSocketChannel) async {
        guard let pcm = source.pcm16(atRate: Double(rate)) else { return }
        let bytesPerFrame = rate / 10 * 2       // 100ms 分の Int16
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + bytesPerFrame, pcm.count)
            let chunk = pcm.subdata(in: offset..<end)
            let payload: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString(),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                try? await channel.send(data)
            }
            offset = end
        }
        if let commit = try? JSONSerialization.data(
            withJSONObject: ["type": "input_audio_buffer.commit"]) {
            try? await channel.send(commit)
        }
    }

    // MARK: - 対照: macOS のエンジン

    private static func transcribeWithApple(_ source: AudioSource) async {
        let provider = AppleSpeechProvider()
        let request = TranscriptionRequest(locale: Locale(identifier: "ja-JP"))
        guard case .ready = await provider.readiness(for: request) else {
            print("  ja-JP のモデルが未取得です（make download-model）")
            return
        }
        let format = await provider.preferredFormat(for: request)
        guard let pcm = source.pcm16(atRate: format.sampleRate),
              let session = try? await provider.startSession(request) else {
            print("  セッションを開始できません")
            return
        }

        let started = ContinuousClock.now
        // イベントを集める。TranscriptBuffer は値型なので、
        // Task の外から触らず、収集し終えてから組み立てる。
        let collector = Task { () -> [TranscriptionEvent] in
            var collected: [TranscriptionEvent] = []
            for try await event in session.events { collected.append(event) }
            return collected
        }

        let bytesPerFrame = Int(format.sampleRate) / 10 * 2
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + bytesPerFrame, pcm.count)
            try? await session.append(AudioChunk(
                format: format, samples: pcm.subdata(in: offset..<end)))
            offset = end
        }
        try? await session.finish()
        var buffer = TranscriptBuffer()
        for event in (try? await collector.value) ?? [] { buffer.apply(event) }
        print("  \(ms(since: started)) ms")
        print("  結果: \(buffer.bestEffortText)")
    }

    // MARK: - 補助

    /// ベース URL から realtime の候補を作る。
    /// **パスは推測が混じる**ので、順に試して通ったものを報告する。
    static func candidates(from base: URL) -> [URL] {
        var trimmed = base.absoluteString
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let wss = trimmed
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        let root = wss.hasSuffix("/realtime")
            ? String(wss.dropLast("/realtime".count)) : wss
        return [
            "\(root)/realtime?intent=transcription",
            "\(root)/realtime",
        ].compactMap(URL.init(string:))
    }

    /// Azure は `api-key`、OpenAI は `Authorization`。ホスト名から選ぶ。
    static func authHeader(for host: String) -> String {
        host.hasSuffix(".openai.azure.com") ? "api-key" : "Authorization"
    }

    static func injection(for host: String, _ ref: CredentialRef) -> SecretInjection {
        host.hasSuffix(".openai.azure.com") ? .raw(ref) : .bearer(ref)
    }

    /// **キーの値には触れない。** 口座名を組み立てるだけ。
    ///
    /// 値が現れるのは `EgressGate.applyingSecrets` の中だけで、
    /// この道具はヘッダを組み立てず、出力もしない。
    private static func resolveCredentialRef(_ options: Options, host: String) -> CredentialRef? {
        if let name = options.keyEnvName { return CredentialRef(account: name) }
        if options.useKeychain { return CredentialRef(account: "probe@\(host.lowercased())") }
        return nil
    }

    /// 鍵の置き場所に応じた `CredentialStore` を選ぶ。
    private static func store(_ options: Options) -> any CredentialStore {
        options.keyEnvName != nil ? EnvironmentCredentialStore() : KeychainStore()
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000
                   + d.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func describe(_ route: ProxyResolver.Route) -> String {
        switch route {
        case .direct: "直結"
        case .proxied(let hosts): "プロキシ経由 \(hosts.joined(separator: ", "))"
        case .needsPAC: "PAC の評価が必要"
        case .undeterminable: "判定不能"
        }
    }

    /// URLSession の失敗を切り分けやすい日本語にする。
    /// **認証失敗と到達不能を区別できないと、次に何を直せばよいか分からない。**
    static func describeTransport(_ error: any Error) -> String {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else {
            return "切断されました（\(e.localizedDescription)）"
        }
        return switch e.code {
        case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication:
            "認証に失敗しました。Keychain の鍵とヘッダ名（Azure は api-key）を確認してください"
        case NSURLErrorBadServerResponse:
            "ハンドシェイクが 101 になりませんでした。URL のパスが違うか、プロキシが Upgrade を剥がしています"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
            "接続できません。ホスト名とプロキシ設定を確認してください"
        case NSURLErrorTimedOut:
            "応答がありません（タイムアウト）"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            "TLS を検証できません。社内 CA なら System キーチェーンに追加が要ります"
        default:
            "切断されました（URLError \(e.code): \(e.localizedDescription)）"
        }
    }

    private static func shortReason(_ error: any Error) -> String {
        if let e = error as? VoinpError, case .egressDenied(let reason) = e {
            return "ゲートが拒否: \(reason)"
        }
        return (error as NSError).localizedDescription
    }
}

/// WAV を読んで、任意のサンプルレートの mono Int16 に変換する。
struct AudioSource {
    let file: AVAudioFile
    var duration: Double {
        Double(file.length) / file.processingFormat.sampleRate
    }

    static func load(path: String) -> AudioSource? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path))
        else { return nil }
        return AudioSource(file: file)
    }

    /// 指定レートの mono Int16 バイト列にする。
    func pcm16(atRate rate: Double) -> Data? {
        file.framePosition = 0
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil
        else { return nil }

        let ratio = rate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return nil }

        // `convert` のブロックは @Sendable 扱いなので、状態を箱に入れて渡す。
        let box = ConversionBox(input: input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            box.next(status)
        }
        guard error == nil, let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * 2)
    }
}

/// `AVAudioConverter.convert` のブロックへ入力バッファを渡すための箱。
/// `AVAudioPCMBuffer` が Sendable でないため、1 スレッドでしか使わないことを
/// 明示した上で包む（変換は同期的に 1 回だけ回る）。
final class ConversionBox: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private var consumed = false

    init(input: AVAudioPCMBuffer) { self.input = input }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if consumed { status.pointee = .endOfStream; return nil }
        consumed = true
        status.pointee = .haveData
        return input
    }
}

extension RealtimeProbe.Options {
    /// 引数を解釈する。**キーの値は受け取らない。**
    /// 受けるのは Keychain の口座を使う指示だけで、値は `EgressGate` の中でしか現れない。
    static func parse(_ arguments: [String]) -> Self {
        var o = Self()
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count
            else { return nil }
            return arguments[i + 1]
        }
        o.baseURL = value("--url") ?? ""
        o.model = value("--model") ?? "gpt-live-transcribe"
        o.wavPath = value("--wav")
        o.delay = value("--delay") ?? "low"
        o.keyEnvName = value("--key-env")
        o.useKeychain = o.keyEnvName == nil
        if let l = value("--languages") { o.languages = l.split(separator: ",").map(String.init) }
        if let k = value("--keywords") { o.keywords = k.split(separator: ",").map(String.init) }
        if let r = value("--rate"), let n = Int(r) { o.rates = [n] }
        o.compareWithApple = !arguments.contains("--no-compare")
        return o
    }
}

/// 環境変数に置かれた鍵を読む。**口座名が環境変数名そのもの。**
///
/// 読み出しは `EgressGate` の中でしか起こらず、値はヘッダに載る以外の経路へ出ない。
/// 書き込みと削除は持たない（開発用の読み取り専用の口）。
struct EnvironmentCredentialStore: CredentialStore {
    func read(_ ref: CredentialRef) throws -> String? {
        ProcessInfo.processInfo.environment[ref.account]
    }
    func write(_ value: String, to ref: CredentialRef) throws {}
    func delete(_ ref: CredentialRef) throws {}
}
