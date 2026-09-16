import Foundation
import VoinpCore

/// Realtime のイベントを voinp の `TranscriptionEvent` に翻訳する。
///
/// **この実装で最も壊れやすい場所。** 2 つの意味論が逆を向いている:
///
/// | | 意味 |
/// |---|---|
/// | Realtime の `delta` | **追記分**（`"delta": "今日は"` の次に `"いい天気"`） |
/// | voinp の `.partial` | 直前を**丸ごと置換**（`TranscriptBuffer` の規約） |
///
/// `delta` をそのまま `.partial` に流すと、HUD には最後の断片しか出ない。
/// ここで累積してから置換として出す。
///
/// I/O を一切しない純粋な struct なので、実エンドポイントなしで全分岐を検査できる。
public struct RealtimeTranscriptAssembler: Sendable {

    /// ターンごとの累積。`item_id` が同一ターンの全 delta で共通なので、
    /// これがターンの識別子になる。
    private var pending: [String: String] = [:]
    /// 到着順を保つ。辞書の順序は不定なので別に持つ。
    private var order: [String] = []
    /// 確定済みのターン。**同じ `item_id` で 2 回確定させない。**
    private var completed: Set<String> = []
    private(set) public var hasCommitted = false

    public init() {}

    public mutating func ingest(_ event: RealtimeWireEvent) -> [TranscriptionEvent] {
        switch event {
        case .sessionCreated, .sessionUpdated, .ignored, .serverError:
            return []

        case .transcriptDelta(let id, let delta):
            guard !delta.isEmpty else { return [] }
            if pending[id] == nil { order.append(id) }
            pending[id, default: ""] += delta
            return [.partial(volatileText)]

        case .transcriptCompleted(let id, let transcript):
            // 同じターンを 2 回確定させない。重複した文が挿入される。
            guard !completed.contains(id) else { return [] }
            forget(id)

            // **空の確定を出さない。** `TranscriptBuffer` は `.finalized` を受けると
            // volatileTail を捨てるので、空で出すと `bestEffortText` が空になり、
            // 「話したのに何も入らない」が起きる。
            guard !transcript.isEmpty else {
                return pending.isEmpty ? [] : [.partial(volatileText)]
            }

            completed.insert(id)
            hasCommitted = true
            // audioRange は付けない。Realtime は音声区間を返さないので、
            // 嘘の範囲を入れるより nil のほうがよい。
            // そのぶん TranscriptBuffer 側の重複排除が効かないため、
            // **重複排除はこの型が item_id で担保する**（Apple 版と責任が逆）。
            return [.finalized(TranscriptSegment(text: transcript)), .partial(volatileText)]

        case .transcriptFailed(let id):
            forget(id)
            return [.partial(volatileText)]
        }
    }

    /// 確定が来ないまま終わるときに、溜まっている分を確定として拾う。
    ///
    /// **捨ててはいけない。** サーバーが `completed` を返さないまま切れることがあり、
    /// そこで黙って捨てると「話したのに何も入らない」になる。
    public mutating func finish() -> [TranscriptionEvent] {
        let leftover = volatileText
        pending.removeAll()
        order.removeAll()
        guard !leftover.isEmpty else { return [] }
        hasCommitted = true
        return [.finalized(TranscriptSegment(text: leftover))]
    }

    /// まだ確定していない分の累積。到着順に連結する。
    private var volatileText: String {
        order.compactMap { pending[$0] }.joined()
    }

    private mutating func forget(_ id: String) {
        pending[id] = nil
        order.removeAll { $0 == id }
    }
}
