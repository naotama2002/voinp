import Foundation

/// 確定結果と暫定結果をマージして、セッション中の「唯一の真実」を保つ。
///
/// `DictationCoordinator` actor の内部にのみ存在し、UI へは
/// `snapshot()` の結果だけをスロットルして流す。
///
/// 不変条件:
/// - `.partial` は暫定分を**置換**する。決して追記しない。
/// - `.finalized` は確定分に**追記**し、暫定分を**破棄**する。
///   暫定分は同じ音声区間のより粗い推定なので、確定が来たら残してはいけない。
/// - 確定結果が `audioRange` を持つ場合、**既に確定済みの区間と重なるものは捨てる**。
///   エンジンによっては同じ区間を再確定して送ってくることがあり、
///   素朴に追記すると文が二重になる。
/// - 到着順は保証されない。`audioRange` があれば開始時刻順に整列して連結する。
public struct TranscriptBuffer: Equatable, Sendable {

    private var segments: [TranscriptSegment] = []
    /// 時刻情報を持たない確定結果は、到着順に積むしかない。
    private var untimedText: String = ""
    private var volatileTail: String = ""
    /// 確定済み区間の終端。これ以前に始まる区間は再確定とみなす。
    private var committedEnd: Duration?

    public init() {}

    public mutating func apply(_ event: TranscriptionEvent) {
        switch event {
        case .partial(let text):
            volatileTail = text

        case .finalized(let segment):
            volatileTail = ""
            guard let range = segment.audioRange else {
                untimedText += segment.text
                return
            }
            // 重なり判定は「確定済み終端より前か」ではなく
            // 「既存セグメントと実際に重なるか」で行う。
            // 前者にすると、遅れて届いた前半の区間を誤って捨ててしまう。
            let overlapsExisting = segments.contains { existing in
                guard let r = existing.audioRange else { return false }
                return r.overlaps(range)
            }
            guard !overlapsExisting else { return }

            segments.append(segment)
            segments.sort { $0.audioRange!.lowerBound < $1.audioRange!.lowerBound }
            committedEnd = max(committedEnd ?? range.upperBound, range.upperBound)

        case .ended:
            volatileTail = ""
        }
    }

    /// 確定分のみ。挿入に使うのは常にこちら。
    public var committed: String {
        segments.map(\.text).joined() + untimedText
    }

    public func snapshot() -> TranscriptSnapshot {
        TranscriptSnapshot(committed: committed, volatileTail: volatileTail)
    }

    /// 挿入直前に呼ぶ。前後の空白を落とした確定テキスト。
    public var finalText: String {
        committed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { finalText.isEmpty }

    public mutating func reset() {
        segments.removeAll()
        untimedText = ""
        volatileTail = ""
        committedEnd = nil
    }
}
