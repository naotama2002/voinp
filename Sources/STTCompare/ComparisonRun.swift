import Foundation
import VoinpCore

/// 比較する 1 エンジン分の設定。
public struct Engine: Sendable, Identifiable {
    public let id: String
    /// 画面に出す名前。
    public let displayName: String
    /// このエンジンが要求する取り込みフォーマット。
    /// **揃えない。** 16k のエンジンに 24k を水増しして渡すと不利に働く。
    public let format: AudioFormatDescription
    /// 実装を作る。毎回作るのは、設定を変えたときに古いまま使わないため。
    public let makeProvider: @Sendable () -> any TranscriptionProvider

    public init(id: String, displayName: String, format: AudioFormatDescription,
                makeProvider: @escaping @Sendable () -> any TranscriptionProvider) {
        self.id = id
        self.displayName = displayName
        self.format = format
        self.makeProvider = makeProvider
    }
}

/// 1 エンジンの認識状況。画面はこれを並べて描く。
public struct EngineResult: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case listening
        case finished
        /// 失敗しても比較は続ける。**1 つ落ちても他を止めない。**
        case failed(String)
    }

    public var id: String
    public var displayName: String
    public var state: State = .idle
    /// 確定分。
    public var committed = ""
    /// 暫定分。確定が来たら消える。
    public var volatile = ""

    /// 録音開始から**最初の文字が出るまで**。体感の速さ。
    public var firstTextMs: Int?
    /// 録音停止から**確定が出そろうまで**。待たされ方。
    public var finalizeMs: Int?

    public var text: String { committed + volatile }

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// 1 本の音声を複数のエンジンへ同時に流し、結果を並べて集める。
///
/// ## 公平に比べるために守ること
///
/// **1. 同じ音声を渡す。** マイクは 1 回だけ開き、取り込んだ PCM を分配する。
/// エンジンごとに録り直すと、話し方の違いが結果の違いに化ける。
///
/// **2. レートは各エンジンの要求に合わせて落とす。**
/// 16kHz のエンジンに 24kHz を水増しして渡すのは不利に働く。
/// ハードウェアの取り込みから各々へ**ダウンサンプル**する。
///
/// **3. 基準時刻を 1 つにする。** レイテンシは録音開始・停止の時刻から測る。
/// エンジンごとに別の基準で測ると比較にならない。
///
/// **4. 1 つ落ちても止めない。** 接続に失敗したエンジンは `.failed` にして、
/// 残りの比較を続ける。全部止まると何も分からない。
public actor ComparisonRun {

    public struct Update: Sendable {
        public let results: [EngineResult]
    }

    public nonisolated let updates: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation

    private let engines: [Engine]
    private var results: [String: EngineResult] = [:]
    private var order: [String] = []

    private var sessions: [String: any TranscriptionSession] = [:]
    /// セッションが繋がる前に届いた音声。**捨てない。**
    /// クラウドのハンドシェイクは実測で約 1 秒。捨てると冒頭の語が消える
    /// （「kintone の API で…」が「API で…」になった）。
    /// 上限 150 チャンク ≒ 15 秒で、超えたら古いものから落とす。
    private var pending: [String: [AudioChunk]] = [:]
    private let pendingLimit = 150
    private var pumps: [Task<Void, Never>] = []
    private var startedAt: ContinuousClock.Instant?
    private var stoppedAt: ContinuousClock.Instant?

    public init(engines: [Engine]) {
        self.engines = engines
        self.order = engines.map(\.id)
        for engine in engines {
            results[engine.id] = EngineResult(id: engine.id, displayName: engine.displayName)
        }
        let parts = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.updates = parts.stream
        self.continuation = parts.continuation
    }

    /// 全エンジンのセッションを開始する。
    /// **並行に起こす。** 直列だと後ろのエンジンほど接続が遅れ、
    /// レイテンシの比較が歪む。
    public func start(request: TranscriptionRequest) async {
        startedAt = .now
        stoppedAt = nil

        await withTaskGroup(of: (String, Result<any TranscriptionSession, any Error>).self) { group in
            for engine in engines {
                group.addTask {
                    do {
                        let provider = engine.makeProvider()
                        return (engine.id, .success(try await provider.startSession(request)))
                    } catch {
                        return (engine.id, .failure(error))
                    }
                }
            }
            for await (id, outcome) in group {
                switch outcome {
                case .success(let session):
                    sessions[id] = session
                    update(id) { $0.state = .listening }
                    consume(session, for: id)
                    // 接続前に届いていた音声を流し込む。
                    await drainPending(for: id, into: session)
                case .failure(let error):
                    update(id) { $0.state = .failed(Self.describe(error)) }
                    pending[id] = nil   // 送り先が無いので保持しない
                }
            }
        }
        publish()
    }

    /// 取り込んだ音声を全エンジンへ配る。
    /// **待たない。** 1 つのエンジンが詰まっても他を止めない。
    public func append(_ chunk: AudioChunk, for engineID: String) async {
        // まだ繋がっていないなら溜める。**捨てない。**
        guard let session = sessions[engineID] else {
            var queue = pending[engineID] ?? []
            queue.append(chunk)
            if queue.count > pendingLimit { queue.removeFirst(queue.count - pendingLimit) }
            pending[engineID] = queue
            return
        }
        try? await session.append(chunk)
    }

    /// 繋がった時点で、溜めた分を順番に流し込む。
    private func drainPending(for engineID: String,
                              into session: any TranscriptionSession) async {
        guard let queue = pending.removeValue(forKey: engineID), !queue.isEmpty else { return }
        for chunk in queue { try? await session.append(chunk) }
    }

    public func stop() async {
        stoppedAt = .now
        for (id, session) in sessions {
            do {
                try await session.finish()
            } catch {
                update(id) { $0.state = .failed(Self.describe(error)) }
            }
        }
        publish()
    }

    public func cancel() async {
        for session in sessions.values { await session.cancel() }
        for pump in pumps { pump.cancel() }
        sessions.removeAll()
        pending.removeAll()
        continuation.finish()
    }

    public var snapshot: [EngineResult] { order.compactMap { results[$0] } }

    // MARK: - 収集

    private func consume(_ session: any TranscriptionSession, for id: String) {
        let task = Task { [weak self] in
            do {
                for try await event in session.events {
                    await self?.apply(event, for: id)
                }
            } catch {
                await self?.markFailed(id, error)
            }
            await self?.markFinished(id)
        }
        pumps.append(task)
    }

    private func apply(_ event: TranscriptionEvent, for id: String) {
        switch event {
        case .partial(let text):
            update(id) {
                $0.volatile = text
                noteFirstText(&$0)
            }
        case .finalized(let segment):
            update(id) {
                $0.committed += segment.text
                $0.volatile = ""
                noteFirstText(&$0)
            }
        case .ended:
            update(id) {
                $0.state = .finished
                if let stoppedAt, $0.finalizeMs == nil {
                    $0.finalizeMs = Self.ms(from: stoppedAt)
                }
            }
        }
        publish()
    }

    /// 最初の文字が出た時刻を記録する。**確定でも暫定でも、先に出たほう。**
    private func noteFirstText(_ result: inout EngineResult) {
        guard result.firstTextMs == nil, !result.text.isEmpty, let startedAt else { return }
        result.firstTextMs = Self.ms(from: startedAt)
    }

    private func markFailed(_ id: String, _ error: any Error) {
        update(id) { $0.state = .failed(Self.describe(error)) }
        publish()
    }

    private func markFinished(_ id: String) {
        update(id) {
            if case .failed = $0.state { return }
            $0.state = .finished
            if let stoppedAt, $0.finalizeMs == nil {
                $0.finalizeMs = Self.ms(from: stoppedAt)
            }
        }
        publish()
    }

    private func update(_ id: String, _ mutate: (inout EngineResult) -> Void) {
        guard var result = results[id] else { return }
        mutate(&result)
        results[id] = result
    }

    private func publish() {
        continuation.yield(Update(results: snapshot))
    }

    private static func ms(from start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000
                   + d.components.attoseconds / 1_000_000_000_000_000)
    }

    /// 失敗の理由を短く。**本文は含めない。**
    private static func describe(_ error: any Error) -> String {
        if let e = error as? VoinpError, case .egressDenied(let reason) = e {
            return "送信が許可されていません（\(reason)）"
        }
        return (error as NSError).localizedDescription
    }
}
