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

    /// 画面表示用。
    ///
    /// **挿入されるテキストと同じ加工を通す。**
    /// 認識中の表示だけ素通しにしていたため、
    /// 画面には「。a大阪に」と出るのに入力は「。大阪に」という食い違いが起きた。
    public func snapshot() -> TranscriptSnapshot {
        TranscriptSnapshot(committed: Self.removeStrayFragments(committed),
                           volatileTail: Self.removeStrayFragments(volatileTail))
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
    /// 日本語の発話に単独の ASCII 英字が現れることがある
    /// （「〜行ってきました。a大阪に〜」）。和文の中に単独の英字が来る余地はない。
    ///
    /// **判定は「直後が和字か」で行う。** 直前の文字で判定していたときは
    /// 句読点の直後しか拾えず、空白や改行を挟んだ場合に取りこぼした。
    ///
    /// **英文は壊さない。** "I went to Tokyo. A penguin…" の I や A は
    /// 直後が ASCII なので対象にならない。
    public static func removeStrayFragments(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        /// ひらがな・カタカナ・漢字・和文の記号。
        func isJapanese(_ c: Character) -> Bool {
            guard let v = c.unicodeScalars.first else { return false }
            return (0x3040...0x309F).contains(v.value)   // ひらがな
                || (0x30A0...0x30FF).contains(v.value)   // カタカナ
                || (0x4E00...0x9FFF).contains(v.value)   // 漢字
                || (0x3000...0x303F).contains(v.value)   // 和文の記号（。、「」）
                || (0xFF00...0xFFEF).contains(v.value)   // 全角英数・記号
        }

        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            let ch = text[index]
            let nextIndex = text.index(after: index)
            let next: Character? = nextIndex < text.endIndex ? text[nextIndex] : nil

            // 単独の ASCII 英字で、直後が和字なら断片とみなす。
            // 直前は問わない（句読点・空白・改行・和字のいずれでも起きる）。
            // ただし直前が ASCII 英数字なら単語の一部なので残す（"Kintone" の e）。
            let previousIsASCIIWord = result.last.map {
                $0.isASCII && ($0.isLetter || $0.isNumber)
            } ?? false

            let isStray = ch.isASCII && ch.isLetter
                && !previousIsASCIIWord
                && (next.map(isJapanese) ?? false)

            if isStray {
                index = nextIndex
                continue
            }
            result.append(ch)
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
