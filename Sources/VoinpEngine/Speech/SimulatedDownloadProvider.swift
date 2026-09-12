import Foundation
import VoinpCore

/// ダウンロード待ちの UI を確認するための差し替え実装。
///
/// 本物の音声モデルは SIP 保護下にあり削除できないので、
/// 「未取得の状態」を手元で再現できない。
/// `TranscriptionProvider` の接合部を使って、取得中の挙動だけを再現する。
///
/// 有効化: `VOINP_SIMULATE_DOWNLOAD=1`
///   - `=slow`      進捗を返さない（本物の Speech 資産と同じ挙動。不定表示になる）
///   - それ以外      0→100% の進捗を返す
///
/// 認識そのものは実物に委譲するので、取得完了後は普通に使える。
public struct SimulatedDownloadProvider: TranscriptionProvider {
    public let identifier = "simulated-download"

    private let real = AppleSpeechProvider()
    private let mode: String
    /// プロセス内でのみ「取得済み」を記憶する。再起動すればまた未取得から始まる。
    private static let installed = Installed()

    final class Installed: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isInstalled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func markInstalled() { lock.lock(); value = true; lock.unlock() }
    }

    public init() {
        mode = ProcessInfo.processInfo.environment["VOINP_SIMULATE_DOWNLOAD"] ?? "1"
    }

    public func readiness(for request: TranscriptionRequest) async -> Readiness {
        if Self.installed.isInstalled { return await real.readiness(for: request) }
        return .needsModelDownload(request.locale)
    }

    public func downloadModel(for locale: Locale,
                              progress: @Sendable @escaping (Double) -> Void) async throws {
        if mode == "slow" {
            // 本物の Speech 資産と同じ挙動: 進捗を一切返さないまま完了する。
            // 不定表示と経過秒数が意図どおり出るかを確認できる。
            // 実機の体感に近づけるため 25 秒かける。
            for _ in 0..<50 {
                progress(0)
                try await Task.sleep(for: .milliseconds(500))
            }
        } else {
            for step in 0...20 {
                progress(Double(step) / 20)
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        Self.installed.markInstalled()
        // 実物の予約も行っておく（完了後に普通に使えるように）
        try? await real.downloadModel(for: locale) { _ in }
    }

    public func preferredFormat(for request: TranscriptionRequest) async -> AudioFormatDescription {
        await real.preferredFormat(for: request)
    }

    public func startSession(_ request: TranscriptionRequest) async throws -> any TranscriptionSession {
        try await real.startSession(request)
    }
}
