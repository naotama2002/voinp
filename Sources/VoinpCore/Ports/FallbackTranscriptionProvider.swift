import Foundation

/// 一次の認識が駄目なら二次へ退避する装飾子。
///
/// クラウド認識をローカルで受け止めるために作った。ただし**どのプロバイダにも依存しない**。
/// 「一次が確定テキストを 1 つも出さないまま終わった」という観測可能な事実だけで判断する。
/// 一次側の失敗の型を知る必要がないので、`VoinpCore` に置ける。
///
/// ## 方針（2 つの案が対立したので決着させた）
///
/// - **クラウド → ローカルの退避は行う。ただし呼び出し側が表示できるようにする。**
///   docs の方針は「入力を絶対にブロックしない」。通信の瞬断で発話を失うほうが害が大きい。
///   表示と経路の食い違いは「退避したことを見せる」ことで解消する（黙って切り替えない）。
/// - **ローカル → クラウドの自動切り替えは絶対に行わない。**
/// - **確定テキストを 1 つでも出した後は差し替えない。**
///   音声区間が特定できないので、リプレイすると同じ発話が二重に入る。
///
/// ## `DictationCoordinator` と `SessionMachine` は無変更
///
/// 退避はここで吸収する。状態機械にネットワークの健全性を知らせると、
/// 既にある世代管理（キャンセルとの競合）ともう 1 本の状態が絡んで手に負えなくなる。
public struct FallbackTranscriptionProvider: TranscriptionProvider {
    public let identifier: String
    private let primary: any TranscriptionProvider
    private let secondary: any TranscriptionProvider
    /// 退避したことを呼び出し側へ伝える。**本文は渡さない。**
    private let onDegrade: @Sendable () -> Void

    public init(primary: any TranscriptionProvider,
                secondary: any TranscriptionProvider,
                onDegrade: @escaping @Sendable () -> Void = {}) {
        self.primary = primary
        self.secondary = secondary
        self.onDegrade = onDegrade
        self.identifier = primary.identifier
    }

    /// 一次が使えないなら二次の準備状態をそのまま返す。
    ///
    /// **一次が使えても二次の資産は要る。** 退避先にモデルが無ければ
    /// 落ちたときに何も残らないので、そのときは取得を促す。
    public func readiness(for request: TranscriptionRequest) async -> Readiness {
        guard case .ready = await primary.readiness(for: request) else {
            return await secondary.readiness(for: request)
        }
        if case .needsModelDownload(let locale) = await secondary.readiness(for: request) {
            return .needsModelDownload(locale)
        }
        return .ready
    }

    /// **二次へ委譲する。** 一次（クラウド）に取得すべき資産は無い。
    public func downloadModel(for locale: Locale,
                              progress: @Sendable @escaping (Double) -> Void) async throws {
        try await secondary.downloadModel(for: locale, progress: progress)
    }

    /// 取り込みのフォーマット。
    ///
    /// **一次が使えないときは二次に合わせる。** 無条件に一次を返していたため、
    /// クラウドが未設定なのに 24kHz で取り込み、16kHz の Apple エンジンへ流していた。
    /// 実機で「音量は出ているのに 0 文字」という形で踏んだ。
    ///
    /// 一次が使えるときは一次に合わせる。途中で退避したら、そのときは
    /// 二次側がサンプルレートの違いを吸収する（`AudioResampler`）。
    public func preferredFormat(for request: TranscriptionRequest) async -> AudioFormatDescription {
        guard case .ready = await primary.readiness(for: request) else {
            return await secondary.preferredFormat(for: request)
        }
        return await primary.preferredFormat(for: request)
    }

    public func startSession(_ request: TranscriptionRequest) async throws
        -> any TranscriptionSession {
        // 一次が最初から使えないなら、黙って二次で始める。ユーザーには見えない。
        guard case .ready = await primary.readiness(for: request) else {
            return try await secondary.startSession(request)
        }
        let session = try await primary.startSession(request)
        return FallbackTranscriptionSession(
            primary: session, request: request, secondary: secondary, onDegrade: onDegrade)
    }
}

/// 一次を流しつつ、駄目なら二次へ差し替えるセッション。
public actor FallbackTranscriptionSession: TranscriptionSession {

    public nonisolated let events: AsyncThrowingStream<TranscriptionEvent, any Error>
    private let continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation

    private let request: TranscriptionRequest
    private let secondary: any TranscriptionProvider
    private let onDegrade: @Sendable () -> Void

    private var active: any TranscriptionSession
    /// 差し替え用に保持している音声。**確定が出たら捨てる**（メモリを返す）。
    private var replay: [AudioChunk] = []
    private let replayLimit: Int
    /// 確定テキストが 1 つでも出たか。出た後は差し替えない。
    private var committed = false
    private var swapped = false
    private var ended = false
    private var pump: Task<Void, Never>?

    init(primary: any TranscriptionSession, request: TranscriptionRequest,
         secondary: any TranscriptionProvider,
         onDegrade: @escaping @Sendable () -> Void,
         replayLimit: Int = 900) {          // 100ms × 900 ≒ 90 秒
        self.active = primary
        self.request = request
        self.secondary = secondary
        self.onDegrade = onDegrade
        self.replayLimit = replayLimit
        let parts = AsyncThrowingStream<TranscriptionEvent, any Error>.makeStream()
        self.events = parts.stream
        self.continuation = parts.continuation
        Task { await self.startPump(from: primary, isPrimary: true) }
    }

    public func append(_ chunk: AudioChunk) async throws {
        guard !ended else { return }
        // 確定が出るまでは差し替えに備えて持っておく。
        if !committed, !swapped {
            replay.append(chunk)
            if replay.count > replayLimit { replay.removeFirst(replay.count - replayLimit) }
        }
        try await active.append(chunk)
    }

    public func finish() async throws {
        guard !ended else { return }
        try await active.finish()
    }

    public func cancel() async {
        guard !ended else { return }
        ended = true
        pump?.cancel()
        await active.cancel()
        continuation.finish()
    }

    // MARK: - 監視と差し替え

    private func startPump(from session: any TranscriptionSession, isPrimary: Bool) {
        pump = Task { [weak self] in
            do {
                for try await event in session.events {
                    await self?.forward(event, isPrimary: isPrimary)
                }
            } catch {
                // 一次がエラーで終わった場合も、退避の判断材料としては同じ。
            }
            await self?.streamFinished(isPrimary: isPrimary)
        }
    }

    private func forward(_ event: TranscriptionEvent, isPrimary: Bool) {
        guard !ended else { return }
        if case .finalized = event {
            committed = true
            // 差し替えの目が無くなったのでメモリを返す。
            replay.removeAll(keepingCapacity: false)
        }
        // 一次の `.ended` は握りつぶす。差し替えるかもしれないので、
        // ここで流すと `SessionMachine` が先に進んでしまう。
        if case .ended = event, isPrimary, !committed { return }
        continuation.yield(event)
        if case .ended = event { ended = true; continuation.finish() }
    }

    private func streamFinished(isPrimary: Bool) async {
        guard !ended else { return }

        // 二次まで終わったなら、もう後が無い。
        guard isPrimary, !swapped else {
            ended = true
            continuation.finish()
            return
        }

        // **確定が出ていれば差し替えない。** リプレイすると文が二重になる。
        guard !committed else {
            ended = true
            continuation.finish()
            return
        }

        await swapToSecondary()
    }

    private func swapToSecondary() async {
        swapped = true
        onDegrade()

        let session: any TranscriptionSession
        do {
            session = try await secondary.startSession(request)
        } catch {
            // 退避先も駄目。**エラーで終わらせない。**
            ended = true
            continuation.finish()
            return
        }

        active = session
        startPump(from: session, isPrimary: false)

        // 保持していた音声を順番に流し直す。
        // サンプルレートが違っても、二次側が chunk.format を見て合わせる。
        let buffered = replay
        replay.removeAll(keepingCapacity: false)
        for chunk in buffered {
            try? await session.append(chunk)
        }
    }
}
