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
