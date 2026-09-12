import SwiftUI
import VoinpCore
import VoinpEngine

struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        if model.needsSetup {
            // 使えない状態。何が足りないかを出し、セットアップへ一本道にする。
            Text(shortfall)
            Button("セットアップを開く…") { model.presentSetup?() }
            Divider()
        } else {
            Text(model.privacyHeadline)
            Divider()
            Button(model.phase.isListening ? "録音を停止" : "録音を開始") {
                model.toggleDictation()
            }
            if model.phase.isListening {
                Button("キャンセル") { model.cancelDictation() }
            }
            Divider()
            Text("ホットキー: \(model.settings.hotkey.binding)（\(behaviorLabel)）")
            Text("認識: \(model.settings.transcription.locale)")
        }

        if let e = model.lastError { Text("直近のエラー: \(e)") }

        Divider()
        Button("設定…") { model.presentSettings?() }
            .keyboardShortcut(",")
        Button("Voinp を終了") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// 何が足りないかを 1 行で。
    private var shortfall: String {
        var lacking: [String] = model.missingPermissions.map {
            switch $0 {
            case .microphone: "マイク"
            case .accessibility: "アクセシビリティ"
            }
        }
        if model.modelReadiness != .ready { lacking.append("音声モデル") }
        return lacking.isEmpty ? "セットアップが必要です"
                               : "セットアップが必要: \(lacking.joined(separator: " / "))"
    }

    private var behaviorLabel: String {
        switch model.settings.hotkey.behavior {
        case "hold":   "押している間"
        case "toggle": "押して開始・押して終了"
        default:       "長押し / 短押しどちらでも"
        }
    }

}
