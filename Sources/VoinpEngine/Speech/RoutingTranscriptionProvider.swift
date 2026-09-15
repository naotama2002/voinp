import Foundation
import Synchronization
import VoinpCore

/// 設定に従って認識エンジンを選ぶ。
///
/// **`VoinpNet` を知らない。** クラウド側の実装は closure で注入されるので、
/// `VoinpEngine` が非ネットワークである性質（`scripts/verify-privacy.sh` の検査 3）
/// は保たれる。オフライン版では closure が nil のまま渡り、
/// クラウドを選ぼうとしても必ずローカルに倒れる。
///
/// **セッションを開始するたびに現在の設定を読む。** 起動時にコピーして抱えると、
/// 設定を変えても再起動するまで反映されない（校正プロンプトで実際に踏んだ）。
public final class RoutingTranscriptionProvider: TranscriptionProvider, Sendable {
    public let identifier = "routing"

    private let local: any TranscriptionProvider
    /// 設定からクラウドの実装を組み立てる。オフライン版では nil。
    private let makeCloud: (@Sendable (Settings) -> (any TranscriptionProvider)?)?
    /// 退避したことを UI へ伝える。
    private let onDegrade: @Sendable () -> Void
    private let settings: Mutex<Settings>

    public init(local: any TranscriptionProvider,
                makeCloud: (@Sendable (Settings) -> (any TranscriptionProvider)?)?,
                settings: Settings,
                onDegrade: @escaping @Sendable () -> Void = {}) {
        self.local = local
        self.makeCloud = makeCloud
        self.settings = Mutex(settings)
        self.onDegrade = onDegrade
    }

    /// 設定が変わったら差し替える。`AppModel.update` から呼ぶ。
    public func settingsChanged(_ next: Settings) {
        settings.withLock { $0 = next }
    }

    /// いま使うべき実装。
    ///
    /// クラウドを返すのは **`cloudTranscriptionDestination` が非 nil のとき**だけ。
    /// あれが旗印の唯一の分岐点で、5 条件すべてを要求する。
    /// ここで独自の条件を書き足してはいけない。
    private func active() -> any TranscriptionProvider {
        let current = settings.withLock { $0 }
        guard current.cloudTranscriptionDestination != nil,
              let cloud = makeCloud?(current)
        else { return local }
        // クラウドを一次、ローカルを退避先にする。
        return FallbackTranscriptionProvider(
            primary: cloud, secondary: local, onDegrade: onDegrade)
    }

    /// クラウドが選ばれているのに実装が無い（オフライン版）。
    /// **黙ってローカルで動かすが、呼び出し側が気づけるようにする。**
    public var cloudSelectedButUnavailable: Bool {
        let current = settings.withLock { $0 }
        return current.transcription.provider == CloudTranscriptionProviderID.openAIRealtime
            && makeCloud == nil
    }

    // MARK: - TranscriptionProvider

    public func readiness(for request: TranscriptionRequest) async -> Readiness {
        await active().readiness(for: request)
    }

    public func downloadModel(for locale: Locale,
                              progress: @Sendable @escaping (Double) -> Void) async throws {
        try await active().downloadModel(for: locale, progress: progress)
    }

    public func preferredFormat(for request: TranscriptionRequest) async -> AudioFormatDescription {
        await active().preferredFormat(for: request)
    }

    public func startSession(_ request: TranscriptionRequest) async throws
        -> any TranscriptionSession {
        try await active().startSession(request)
    }
}
