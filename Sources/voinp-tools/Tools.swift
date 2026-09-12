import Foundation
import VoinpCore
import VoinpEngine

/// 開発用ユーティリティ。`make download-model` から呼ぶ。
///
/// **`main.swift` にしてはいけない。** Swift 6 では `main.swift` のトップレベルコードが
/// MainActor 隔離されるため、`DispatchSemaphore.wait()` で待つと自分自身をブロックし、
/// 中の `Task` が MainActor に戻れなくなってデッドロックする（実際に踏んだ）。
/// `@main` + `static func main() async` なら素直に待てる。
@main
struct Tools {
    static func main() async {
        let provider = AppleSpeechProvider()
        let identifier = CommandLine.arguments.dropFirst().first ?? "ja-JP"
        let locale = Locale(identifier: identifier)
        let request = TranscriptionRequest(locale: locale)

        switch await provider.readiness(for: request) {
        case .ready:
            print("✅ \(identifier): 取得済み")

        case .unsupported(let why):
            print("❌ \(identifier): \(why)")
            exit(1)

        case .needsModelDownload(let canonical):
            print("⬇️  \(canonical.identifier(.bcp47)) のモデルを取得します…")
            do {
                try await provider.downloadModel(for: canonical) { p in
                    if p >= 1 { print("   100%") }
                }
                let after = await provider.readiness(for: request)
                if after == .ready {
                    print("✅ 完了")
                } else {
                    print("⚠️  取得後も ready になりません: \(after)")
                    exit(1)
                }
            } catch {
                print("❌ 失敗: \(error)")
                exit(1)
            }
        }
    }
}
