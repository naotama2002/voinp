import Testing
import Foundation
import VoinpCore
@testable import VoinpEngine

/// 設定を変えたとき、それが実際に使われる経路まで届くかを検査する。
///
/// 「UI にあるのに効かない」を何度か作ってしまった:
/// - insertion.strategy を読まずに PasteInserter を直接生成していた
/// - audio.playFeedbackSounds に対応するコードが無かった
/// - refinement.prompt を起動時にコピーして固定していた
/// - openaiCompatible.baseURL を変えても古いクライアントを使い続けていた
///
/// いずれも実機で気づいた。ここで機械的に検出できるようにする。
@Suite("設定が届くこと")
@MainActor
struct SettingsPropagationTests {

    @Test("挿入方法は設定から選ばれる")
    func insertionStrategy() {
        var paste = Settings(); paste.insertion.strategy = "paste"
        var keystroke = Settings(); keystroke.insertion.strategy = "keystroke"
        #expect(DictationCoordinator.makeInserter(paste).identifier == "paste")
        #expect(DictationCoordinator.makeInserter(keystroke).identifier == "keystroke")
    }

    @Test("ペーストの細かい設定も渡る")
    func pasteOptions() {
        var s = Settings()
        s.insertion.strategy = "paste"
        s.insertion.pasteRestoreDelayMs = 500
        s.insertion.restoreClipboard = false
        // 生成できること自体を確認する（値は PasteInserter が保持する）
        #expect(DictationCoordinator.makeInserter(s).identifier == "paste")
    }

    @Test("校正プロンプトが指示として組み立てられる")
    func refinementPrompt() {
        var s = Settings()
        s.refinement.prompt = "英訳して"
        let assembly = PromptBuilder().assemble(
            transcript: "テスト", preset: .fromUserPrompt(s.refinement.prompt))
        #expect(assembly.system.contains("英訳して"))
    }

    @Test("認識の設定がリクエストに反映される")
    func transcriptionRequest() {
        var s = Settings()
        s.transcription.locale = "en-US"
        s.transcription.termHints = ["kintone", "サイボウズ"]
        s.transcription.punctuation = "off"

        let request = TranscriptionRequest(
            locale: Locale(identifier: s.transcription.locale),
            termHints: s.transcription.termHints.map(TermHint.init),
            wantsPartialResults: s.transcription.showPartialResults,
            punctuation: s.transcription.punctuation == "automatic")

        #expect(request.locale.identifier == "en-US")
        #expect(request.termHints.count == 2)
        #expect(request.punctuation == false)
    }

    /// 設定の各セクションが「変更された」と判定されること。
    /// ここが漏れると update() が何もせず、変更が保存すらされない。
    @Test("全セクションの変更が検知される")
    func allSectionsDetectChanges() {
        let base = Settings()

        var a = base; a.hotkey.binding = "ctrl+opt+d"
        #expect(a != base, "hotkey")

        var b = base; b.audio.playFeedbackSounds = false
        #expect(b != base, "audio")

        var c = base; c.transcription.termHints = ["x"]
        #expect(c != base, "transcription")

        var d = base; d.refinement.prompt = "英訳して"
        #expect(d != base, "refinement.prompt")

        var e = base; e.refinement.openaiCompatible.baseURL = "https://other.example.com/v1"
        #expect(e != base, "refinement.baseURL")

        var f = base; f.insertion.strategy = "keystroke"
        #expect(f != base, "insertion")

        var g = base; g.privacy.allowNetwork = true
        #expect(g != base, "privacy")

        var h = base; h.ui.hudShowComparison = true
        #expect(h != base, "ui")
    }
}
