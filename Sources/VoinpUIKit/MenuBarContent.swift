import SwiftUI
import VoinpCore
import VoinpEngine

struct MenuBarContent: View {
    let model: AppModel
    let openSetup: () -> Void

    var body: some View {
        Text(model.privacyHeadline)
        Divider()

        if model.missingPermissions.isEmpty {
            Button(model.phase.isListening ? "録音を停止" : "録音を開始") {
                model.toggleDictation()
            }
            if model.phase.isListening {
                Button("キャンセル") { model.cancelDictation() }
            }
        } else {
            // 何をなぜ求めているかを先に出し、操作は 2 段に分ける。
            // 「許可する」= OS のダイアログ、「システム設定を開く」= 手動での付与。
            ForEach(model.missingPermissions, id: \.self) { p in
                Section(title(for: p)) {
                    Text(model.permissionExplanation(p))
                    Button("許可する…") { model.requestPermission(p) }
                    Button("システム設定を開く") { model.openSettings(for: p) }
                }
            }
        }

        Divider()
        Text("ホットキー: \(model.settings.hotkey.binding) (\(model.settings.hotkey.behavior))")
        Text("認識: \(model.settings.transcription.locale)")
        if let p = model.modelProgress, p < 1 {
            Text("モデル取得中 \(Int(p * 100))%")
        }
        if let e = model.lastError { Text("直近のエラー: \(e)") }

        Divider()
        Button("セットアップを開く…") { openSetup() }
        Button("設定ファイルを開く") { openConfigDirectory() }
        Button("Voinp を終了") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func title(for p: SessionError.Permission) -> String {
        switch p {
        case .microphone:    "マイクが未許可"
        case .accessibility: "アクセシビリティが未許可"
        }
    }

    private func openConfigDirectory() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/voinp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
