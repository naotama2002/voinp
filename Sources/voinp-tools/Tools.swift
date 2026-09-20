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
        // 断片除去の確認モード
        if CommandLine.arguments.contains("--check-fragments") {
            let input = ProcessInfo.processInfo.environment["VOINP_SAMPLE"]
                ?? "今日は東京へ。a大阪に。aそれから京都へ。"
            let out = TranscriptBuffer.removeStrayFragments(input)
            print("入力: \(input)")
            print("出力: \(out)")
            print(input == out ? "→ 変化なし（除去が効いていない）" : "→ \(input.count - out.count) 文字を除去")
            return
        }

        // LLM の疎通確認モード
        if CommandLine.arguments.contains("--probe-llm") {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: "--probe-llm"), i + 1 < args.count else {
                print("使い方: voinp-tools --probe-llm <URL> [--key <APIキー>]")
                exit(1)
            }
            let url = args[i + 1]
            let key = args.firstIndex(of: "--key").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            await ProbeTool.run(urlString: url, apiKey: key)
            return
        }

        // 候補と信頼度を覗くモード
        if CommandLine.arguments.contains("--probe-alternatives") {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: "--probe-alternatives"), i + 1 < args.count else {
                print("使い方: voinp-tools --probe-alternatives <音声ファイル> [--terms kintone,Garoon]")
                exit(1)
            }
            let terms = args.firstIndex(of: "--terms")
                .flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                .map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
                ?? []
            await AlternativesProbe.run(path: args[i + 1], terms: terms)
            return
        }

        let provider = AppleSpeechProvider()
        var args = Array(CommandLine.arguments.dropFirst())

        // 既定でダウンロードまで行う破壊的な挙動なので、確認だけしたい場合の口を用意する。
        // （用意していなかったせいで、状態を見るつもりが 2 ロケール分ダウンロードさせた）
        let checkOnly = args.contains("--check")
        args.removeAll { $0.hasPrefix("--") }

        let identifier = args.first ?? "ja-JP"
        let locale = Locale(identifier: identifier)
        let request = TranscriptionRequest(locale: locale)

        switch await provider.readiness(for: request) {
        case .ready:
            print("✅ \(identifier): 取得済み")

        case .unsupported(let why):
            print("❌ \(identifier): \(why)")
            exit(1)

        case .needsModelDownload(let canonical):
            guard !checkOnly else {
                print("⬜ \(identifier): 未取得（--check のため取得しません）")
                return
            }
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
