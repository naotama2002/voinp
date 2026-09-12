import Foundation
import Synchronization
import VoinpCore
import VoinpEngine

// 日本語認識モデルの取得と状態確認。`make download-model` から呼ぶ。
let provider = AppleSpeechProvider()
let locale = Locale(identifier: CommandLine.arguments.dropFirst().first ?? "ja-JP")
let request = TranscriptionRequest(locale: locale)

let sem = DispatchSemaphore(value: 0)
Task {
    switch await provider.readiness(for: request) {
    case .ready:
        print("✅ \(locale.identifier): 取得済み")
    case .unsupported(let why):
        print("❌ \(locale.identifier): \(why)")
    case .needsModelDownload(let canonical):
        print("⬇️  \(canonical.identifier) のモデルを取得します…")
        do {
            let last = Mutex(-1)
            try await provider.downloadModel(for: canonical) { p in
                let pct = Int(p * 100)
                last.withLock { prev in
                    if pct / 5 != prev / 5 { print("   \(pct)%") }
                    prev = pct
                }
            }
            let after = await provider.readiness(for: request)
            print(after == .ready ? "✅ 完了" : "⚠️  取得後も ready になりません: \(after)")
        } catch {
            print("❌ 失敗: \(error)")
        }
    }
    sem.signal()
}
sem.wait()
