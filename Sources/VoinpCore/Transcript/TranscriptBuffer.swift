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
            //
            // **端点の共有を「重なり」と見なしてはいけない。**
            // ClosedRange.overlaps は [0,2] と [2,4] を true と判定するので、
            // 連続する発話（前の終わりと次の始まりが同時刻）が捨てられてしまう。
            // 実際に区間が食い込んでいる場合だけ重複とする。
            let overlapsExisting = segments.contains { existing in
                guard let r = existing.audioRange else { return false }
                return r.lowerBound < range.upperBound && range.lowerBound < r.upperBound
            }
            guard !overlapsExisting else { return }

            segments.append(segment)
            segments.sort { $0.audioRange!.lowerBound < $1.audioRange!.lowerBound }
            committedEnd = max(committedEnd ?? range.upperBound, range.upperBound)

        case .ended:
            // 確定結果が 1 つも来ていなければ暫定分を残す（bestEffortText の材料）。
            if !segments.isEmpty || !untimedText.isEmpty { volatileTail = "" }
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

    /// 挿入に使うテキスト。
    ///
    /// 確定結果が来ないまま終わる場合（短い発話など）に備えて、
    /// 確定が空なら暫定分を採用する。**ユーザーの発話を落とさないことを優先する。**
    public var bestEffortText: String {
        let committedText = finalText
        let text = committedText.isEmpty
            ? volatileTail.trimmingCharacters(in: .whitespacesAndNewlines)
            : committedText
        return Self.removeStrayFragments(text)
    }

    /// 認識が区切りを誤ったときに混ざる、意味のない断片を落とす。
    ///
    /// 日本語の発話に、和文の句読点の直後に単独の ASCII 文字が現れることがある
    /// （「〜する。aゴルフは〜」）。和文中に単独の英字が来る余地はないので落とす。
    ///
    /// **英文は壊さない。** "I went to Tokyo. A penguin…" の I や A は正当なので、
    /// 和文の句読点（。、！？）に続く場合だけを対象にする。
    /// ASCII の "." や " " の後ろは触らない。
    static func removeStrayFragments(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let japanesePunctuation: Set<Character> = ["。", "、", "！", "？"]

        var result = ""
        var previous: Character?
        var index = text.startIndex

        while index < text.endIndex {
            let ch = text[index]
            let nextIndex = text.index(after: index)
            let next: Character? = nextIndex < text.endIndex ? text[nextIndex] : nil

            // 直前が和文の句読点で、単独の ASCII 英字である場合に落とす。
            //
            // 直後が「英字」なら単語の途中なので残す（"。Slack" の S）。
            // 直後が「数字」なら落とす。和文の直後に "a13" のような
            // 英字 + 数字が来るのは認識の誤りで、正当な語ではない。
            let nextIsLetter = next.map { $0.isASCII && $0.isLetter } ?? false
            let isStray = ch.isASCII && ch.isLetter
                && previous.map { japanesePunctuation.contains($0) } == true
                && !nextIsLetter

            if isStray {
                index = nextIndex
                continue          // previous は句読点のまま保つ
            }
            result.append(ch)
            previous = ch
            index = nextIndex
        }
        return result
    }

    public mutating func reset() {
        segments.removeAll()
        untimedText = ""
        volatileTail = ""
        committedEnd = nil
    }
}
