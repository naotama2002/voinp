import Testing
import VoinpCore
@testable import VoinpEngine

@Suite("挿入方法の選択")
@MainActor
struct InserterSelectionTests {

    /// 設定の strategy が実際に別の実装を選ぶことを確認する。
    /// UI にあるのに効かない設定を作らないための検査。
    @Test("paste を選ぶとペースト実装になる")
    func pasteStrategy() {
        var s = Settings()
        s.insertion.strategy = "paste"
        #expect(DictationCoordinator.makeInserter(s).identifier == "paste")
    }

    @Test("keystroke を選ぶとキー入力実装になる")
    func keystrokeStrategy() {
        var s = Settings()
        s.insertion.strategy = "keystroke"
        #expect(DictationCoordinator.makeInserter(s).identifier == "keystroke")
    }

    @Test("未知の値は既定（ペースト）に倒す")
    func unknownFallsBack() {
        var s = Settings()
        s.insertion.strategy = "nonsense"
        #expect(DictationCoordinator.makeInserter(s).identifier == "paste")
    }
}
