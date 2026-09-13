import Testing
import Foundation
@testable import VoinpCore

@Suite("Settings")
struct SettingsTests {

    @Test("一部のキーだけ書いた設定ファイルを読める")
    func partialConfigDecodes() throws {
        // ユーザーが手で書くのはこういう形。全項目を書かせるのは現実的でない。
        let json = """
        { "schemaVersion": 1, "transcription": { "locale": "en-GB" } }
        """.data(using: .utf8)!
        let s = try Settings.decode(json)
        #expect(s.transcription.locale == "en-GB")
        #expect(s.hotkey.binding == "ctrl+opt+space", "書いていない項目は既定値で埋まる")
        #expect(s.refinement.enabled == false)
    }

    @Test("空の JSON でも既定値で読める")
    func emptyConfigDecodes() throws {
        let s = try Settings.decode("{}".data(using: .utf8)!)
        #expect(s.transcription.locale == "ja-JP")
    }

    @Test("未知のキーがあっても失敗しない")
    func unknownKeysIgnored() throws {
        let json = """
        { "transcription": { "locale": "ja-JP", "futureOption": true }, "somethingNew": 1 }
        """.data(using: .utf8)!
        let s = try Settings.decode(json)
        #expect(s.transcription.locale == "ja-JP")
    }

    @Test("JSON5 のコメントを許容する")
    func json5CommentsAllowed() throws {
        let json = """
        {
          // 認識するロケール
          "transcription": { "locale": "en-GB" },
        }
        """.data(using: .utf8)!
        let s = try Settings.decode(json)
        #expect(s.transcription.locale == "en-GB")
    }

    @Test("encode → decode で往復する")
    func roundTrip() throws {
        var s = Settings()
        s.transcription.locale = "en-GB"
        s.refinement.enabled = true
        let again = try Settings.decode(try s.encoded())
        #expect(again.transcription.locale == "en-GB")
        #expect(again.refinement.enabled == true)
    }
}

@Suite("Settings — 変更の検知")
struct SettingsChangeDetectionTests {

    /// `update` は差分があるときだけ保存・反映する。
    /// 各セクションの変更がきちんと「差分あり」と判定されることを確認する。
    /// ここが壊れると、設定を変えても何も起きない。
    @Test("各セクションの変更が検知される")
    func everySectionDetectsChange() {
        var a = Settings()
        var b = Settings()
        #expect(a == b)

        b.hotkey.binding = "ctrl+opt+d"
        #expect(a.hotkey != b.hotkey, "ホットキー")

        b = Settings(); b.audio.playFeedbackSounds = false
        #expect(a.audio != b.audio, "音")

        b = Settings(); b.transcription.locale = "en-US"
        #expect(a.transcription != b.transcription, "言語")

        b = Settings(); b.insertion.strategy = "keystroke"
        #expect(a.insertion != b.insertion, "挿入方法")

        b = Settings(); b.insertion.pasteRestoreDelayMs = 500
        #expect(a.insertion != b.insertion, "復元待ち時間")

        b = Settings(); b.ui.hudShowText = false
        #expect(a.ui != b.ui, "HUD 表示")

        a.transcription.termHints = ["x"]
        #expect(a.transcription != Settings().transcription, "用語ヒント")
    }
}

@Suite("HUD の比較表示設定")
struct ComparisonSettingTests {
    @Test("既定ではオフ")
    func defaultsOff() {
        #expect(Settings().ui.hudShowComparison == false)
    }

    @Test("設定ファイルから読める")
    func decodesFromConfig() throws {
        let json = #"{ "ui": { "hudShowComparison": true } }"#.data(using: .utf8)!
        let s = try Settings.decode(json)
        #expect(s.ui.hudShowComparison == true)
        #expect(s.ui.hudShowText == true, "他の項目は既定値のまま")
    }
}
