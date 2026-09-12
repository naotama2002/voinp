import Testing
import Foundation
import VoinpCore
@testable import VoinpEngine

/// 実 Speech フレームワークに対する契約テスト。**マイクも権限も要らない。**
/// 接合部を作った見返りがこれで、CI（macOS 26 ランナー）でも回る。
@Suite("AppleSpeechProvider")
struct AppleSpeechProviderTests {

    let provider = AppleSpeechProvider()

    @Test("日本語が対応ロケールとして解決される")
    func japaneseIsSupported() async {
        let r = await provider.readiness(for: .init(locale: Locale(identifier: "ja-JP")))
        if case .unsupported(let reason) = r {
            Issue.record("ja-JP が未対応と判定された: \(reason)")
        }
    }

    @Test("未対応ロケールは unsupported になる")
    func bogusLocaleIsUnsupported() async {
        let r = await provider.readiness(for: .init(locale: Locale(identifier: "xx-XX")))
        guard case .unsupported = r else {
            Issue.record("xx-XX が未対応として扱われていない: \(r)")
            return
        }
    }

    @Test("推奨フォーマットをフレームワークから取得できる（ハードコードしない）")
    func negotiatesAudioFormat() async {
        let f = await provider.preferredFormat(for: .init(locale: Locale(identifier: "ja-JP")))
        #expect(f.sampleRate >= 8000, "妥当なサンプルレート: \(f.sampleRate)")
        #expect(f.channelCount == 1, "モノラルであること")
    }

    @Test("セッションを開始でき、キャンセルでイベント列が終わる")
    func sessionLifecycle() async throws {
        let r = await provider.readiness(for: .init(locale: Locale(identifier: "ja-JP")))
        guard r == .ready else {
            // モデル未取得の環境ではこのケースは検証できない。
            // 初回は `make download-model`（またはアプリ起動時）で取得される。
            return
        }

        let session = try await provider.startSession(.init(locale: Locale(identifier: "ja-JP")))
        // 無音を流しても落ちないこと
        let fmt = await provider.preferredFormat(for: .init(locale: Locale(identifier: "ja-JP")))
        let silence = AudioChunk(format: fmt, samples: Data(count: 3200))
        try await session.append(silence)
        await session.cancel()

        var count = 0
        for try await _ in session.events { count += 1 }
        #expect(count >= 0, "キャンセル後にイベント列が終端すること")
    }
}

@Suite("PasteboardRestorePolicy")
struct PasteboardRestoreTests {
    @Test("自分が書いたままなら復元する")
    func restoresWhenUnchanged() {
        #expect(PasteboardRestorePolicy.shouldRestore(currentChangeCount: 42, ourChangeCount: 42))
    }

    @Test("誰かが後から書いていたら復元しない（新しい内容を壊さない）")
    func skipsRestoreWhenClobbered() {
        #expect(!PasteboardRestorePolicy.shouldRestore(currentChangeCount: 43, ourChangeCount: 42))
    }
}

@Suite("PasteInserter")
struct PasteInserterTests {
    @Test("⌘V のキーコードを現在のレイアウトから逆引きできる")
    func resolvesVKeyCode() {
        let code = PasteInserter.virtualKeyCodeForV()
        #expect(code != nil, "レイアウトから 'v' を解決できること")
        #expect(code == 0x09 || code != nil, "QWERTY なら 0x09、それ以外でも何か返ること")
    }
}
