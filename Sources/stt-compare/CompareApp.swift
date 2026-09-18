import AppKit
import Foundation
import STTCompare
import SwiftUI
import VoinpCore
import VoinpEngine
import VoinpNet
import VoinpProviders

// 比較ツールの合成ルート。**ネットワークを知るのはここだけ。**
//
// 設定は環境変数で受ける。voinp 本体と違い評価用の道具なので、
// 設定ファイルも同意ダイアログも持たない。そのかわり
// **鍵を渡さなければそのエンジンは比較に出ない**（勝手に送らない）。
//
//   STT_COMPARE_OPENAI_KEY        OpenAI 直
//   STT_COMPARE_AZURE_URL         wss://<resource>.openai.azure.com/openai/v1
//   STT_COMPARE_AZURE_KEY
//   STT_COMPARE_GEMINI_KEY

/// 鍵は値のまま持たず、口座名で参照する。voinp 本体と同じ扱い。
struct EnvironmentCredentials: CredentialStore {
    func read(_ ref: CredentialRef) throws -> String? {
        ProcessInfo.processInfo.environment[ref.account]
    }
    func write(_ value: String, to ref: CredentialRef) throws {}
    func delete(_ ref: CredentialRef) throws {}
}

/// クラウド用のゲート。**ホストを明示的に許可した分だけ通す。**
nonisolated func makeGate(hosts: Set<String>) -> EgressGate {
    let snapshot = EgressPolicySnapshot(
        masterAllow: true, maxClass: .publicInternet,
        allowedHosts: hosts, allowedPurposes: [.transcribe], probeCandidate: nil)
    return EgressGate(policy: { snapshot }, credentials: EnvironmentCredentials())
}

/// 環境変数から比較対象を組み立てる。
///
/// **鍵を渡さなければそのエンジンは比較に出ない。** 勝手に送らない。
nonisolated func buildEngines() -> [Engine] {
    let environment = ProcessInfo.processInfo.environment
    var engines: [Engine] = []

    // macOS のエンジン。**常に入れる。** 比較の基準線になる。
    engines.append(Engine(
        id: "apple",
        displayName: "macOS SpeechAnalyzer",
        format: AudioFormatDescription(sampleRate: 16_000, channelCount: 1, isInt16: true),
        makeProvider: { AppleSpeechProvider() }))

    // gpt-live-transcribe。OpenAI 直か Azure のどちらか。
    if environment["STT_COMPARE_OPENAI_KEY"]?.isEmpty == false {
        let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        engines.append(Engine(
            id: "gpt-live-transcribe",
            displayName: "gpt-live-transcribe (OpenAI)",
            format: AudioFormatDescription(sampleRate: 24_000, channelCount: 1, isInt16: true),
            makeProvider: {
                RealtimeTranscriptionProvider(
                    config: RealtimeSessionConfig(model: "gpt-live-transcribe"),
                    endpoint: url, authHeader: "Authorization",
                    injection: .bearer(CredentialRef(account: "STT_COMPARE_OPENAI_KEY")),
                    handshakeTimeout: .seconds(5),
                    gate: makeGate(hosts: ["api.openai.com"]))
            }))
    } else if let base = environment["STT_COMPARE_AZURE_URL"],
              environment["STT_COMPARE_AZURE_KEY"]?.isEmpty == false,
              let url = URL(string: base.replacingOccurrences(of: "https://", with: "wss://")
                            + "/realtime?intent=transcription"),
              let host = url.host {
        engines.append(Engine(
            id: "gpt-live-transcribe",
            displayName: "gpt-live-transcribe (Azure)",
            format: AudioFormatDescription(sampleRate: 24_000, channelCount: 1, isInt16: true),
            makeProvider: {
                RealtimeTranscriptionProvider(
                    config: RealtimeSessionConfig(model: "gpt-live-transcribe"),
                    endpoint: url, authHeader: "api-key",
                    injection: .raw(CredentialRef(account: "STT_COMPARE_AZURE_KEY")),
                    handshakeTimeout: .seconds(5),
                    gate: makeGate(hosts: [host]))
            }))
    }

    // Gemini。**鍵は URL のクエリに載せない。**
    // 載せると「秘密はゲートの中で初めて値になる」性質が崩れる。ヘッダで渡す。
    if environment["STT_COMPARE_GEMINI_KEY"]?.isEmpty == false {
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/"
                      + "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        engines.append(Engine(
            id: "gemini",
            displayName: "gemini-3.5-transcribe-live",
            format: AudioFormatDescription(sampleRate: 16_000, channelCount: 1, isInt16: true),
            makeProvider: {
                GeminiLiveProvider(
                    config: GeminiLiveConfig(),
                    endpoint: url,
                    injection: .raw(CredentialRef(account: "STT_COMPARE_GEMINI_KEY")),
                    gate: makeGate(hosts: ["generativelanguage.googleapis.com"]))
            }))
    }

    return engines
}

@main
struct CompareApp: App {
    @State private var model = CompareModel(engines: buildEngines())

    var body: some Scene {
        WindowGroup("音声認識エンジンの比較") {
            CompareView(model: model)
        }
    }
}
