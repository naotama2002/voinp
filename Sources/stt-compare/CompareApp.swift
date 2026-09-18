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

/// クラウド用のゲート。**ホストを明示的に許可した分だけ通す。**
nonisolated func makeGate(hosts: Set<String>) -> EgressGate {
    let snapshot = EgressPolicySnapshot(
        masterAllow: true, maxClass: .publicInternet,
        allowedHosts: hosts, allowedPurposes: [.transcribe], probeCandidate: nil)
    return EgressGate(policy: { snapshot }, credentials: CompareCredentials())
}

/// 比較対象を組み立てる。
///
/// **鍵と接続先は、すでに手元にあるものを使う。**
/// 比較ツールのためだけに新しい環境変数を覚えさせない。
///
/// | 何を | どこから |
/// |---|---|
/// | Azure の接続先 | `STT_COMPARE_AZURE_URL` → voinp の `config.json` |
/// | Azure の鍵 | `STT_COMPARE_AZURE_KEY` → `AZURE_API_KEY` → voinp の Keychain |
/// | OpenAI 直の鍵 | `STT_COMPARE_OPENAI_KEY` → `OPENAI_API_KEY` |
/// | Gemini の鍵 | `STT_COMPARE_GEMINI_KEY` → `GEMINI_API_KEY` |
///
/// 比較専用の変数を先に見るが、**無ければ手元にあるものに落ちる**。
/// 他の人が使うときに、比較のためだけの設定を覚えなくてよい。
///
/// **鍵が見つからないエンジンは比較に出ない。** 勝手に送らない。
nonisolated func buildEngines() -> [Engine] {
    let environment = ProcessInfo.processInfo.environment
    var engines: [Engine] = []

    /// 候補を順に見て、最初に値のある変数の**名前**を返す。
    /// **値は返さない。** 鍵が値になるのは `EgressGate` の中だけ。
    func credentialAccount(_ names: [String]) -> String? {
        names.first { environment[$0]?.isEmpty == false }
    }

    // macOS のエンジン。**常に入れる。** 比較の基準線になる。
    engines.append(Engine(
        id: "apple",
        displayName: "macOS SpeechAnalyzer",
        format: AudioFormatDescription(sampleRate: 16_000, channelCount: 1, isInt16: true),
        makeProvider: { AppleSpeechProvider() }))

    let settings = ConfigStore().load().settings
    let realtime = settings.transcription.realtime

    // OpenAI 直。環境変数に鍵があるときだけ。
    if let account = credentialAccount(["STT_COMPARE_OPENAI_KEY", "OPENAI_API_KEY"]) {
        let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        engines.append(Engine(
            id: "openai",
            displayName: "gpt-live-transcribe (OpenAI)",
            format: AudioFormatDescription(sampleRate: 24_000, channelCount: 1, isInt16: true),
            makeProvider: {
                RealtimeTranscriptionProvider(
                    config: RealtimeSessionConfig(model: "gpt-live-transcribe"),
                    endpoint: url, authHeader: "Authorization",
                    injection: .bearer(CredentialRef(account: account)),
                    handshakeTimeout: .seconds(5),
                    gate: makeGate(hosts: ["api.openai.com"]))
            }))
    }

    // Azure。**voinp の設定をそのまま使う。**
    // 本体でクラウド認識を設定してあれば、比較ツールには何も足さなくてよい。
    let azureBase = environment["STT_COMPARE_AZURE_URL"] ?? realtime.endpointURL
    if let url = realtimeURL(from: azureBase), let host = url.host {
        // 鍵は環境変数を優先し、無ければ本体が Keychain に入れたものを使う。
        let injection: SecretInjection? =
            if let account = credentialAccount(["STT_COMPARE_AZURE_KEY", "AZURE_API_KEY"]) {
                .raw(CredentialRef(account: account))
            } else if let ref = CredentialRef.openAIRealtime(host: host),
                      KeychainStore().exists(ref) {
                .raw(ref)
            } else {
                nil
            }

        if let injection {
            let model = realtime.model.isEmpty ? "gpt-live-transcribe" : realtime.model
            engines.append(Engine(
                id: "azure",
                displayName: "\(model) (Azure)",
                format: AudioFormatDescription(sampleRate: 24_000, channelCount: 1,
                                               isInt16: true),
                makeProvider: {
                    RealtimeTranscriptionProvider(
                        config: RealtimeSessionConfig(model: model),
                        endpoint: url, authHeader: "api-key", injection: injection,
                        handshakeTimeout: .seconds(5),
                        gate: makeGate(hosts: [host]))
                }))
        }
    }

    // Gemini。
    if let account = credentialAccount(["STT_COMPARE_GEMINI_KEY", "GEMINI_API_KEY"]) {
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/"
                      + "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        engines.append(Engine(
            id: "gemini",
            displayName: "gemini-3.5-transcribe-live",
            format: AudioFormatDescription(sampleRate: 16_000, channelCount: 1, isInt16: true),
            makeProvider: {
                GeminiLiveProvider(
                    config: GeminiLiveConfig(), endpoint: url,
                    injection: .raw(CredentialRef(account: account)),
                    gate: makeGate(hosts: ["generativelanguage.googleapis.com"]))
            }))
    }

    return engines
}

/// `.app` バンドルを持たない実行ファイルを、GUI アプリとして扱わせる。
///
/// **`swift run` で起動するとウィンドウが出ない。** バンドルが無いので
/// macOS が `.prohibited`（UI を持たないプロセス）とみなすため。
/// voinp 本体は `make install` で `.app` を組み立てるので出るが、
/// 比較ツールは評価用の道具で、毎回インストールさせたくない。
///
/// 起動時に `.regular` へ変え、自分を前面に出す。
final class CompareAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ウィンドウを閉じたら終了する。比較ツールにメニューバー常駐は要らない。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct CompareApp: App {
    @NSApplicationDelegateAdaptor(CompareAppDelegate.self) private var delegate

    init() {
        // 起動時に、何が比較対象になったかを出す。
        // **鍵の値は出さない。** 検出できたかどうかだけ。
        let engines = buildEngines()
        FileHandle.standardError.write(Data(
            ("比較対象: " + engines.map(\.displayName).joined(separator: " / ") + "\n").utf8))
        if engines.count == 1 {
            FileHandle.standardError.write(Data(
                ("クラウドのエンジンが見つかりません。"
                 + "voinp でクラウド認識を設定してあるか、"
                 + "OPENAI_API_KEY / GEMINI_API_KEY を渡してください。\n").utf8))
        }
    }

    @State private var model = CompareModel(engines: buildEngines())

    var body: some Scene {
        WindowGroup("音声認識エンジンの比較") {
            CompareView(model: model)
        }
    }
}
