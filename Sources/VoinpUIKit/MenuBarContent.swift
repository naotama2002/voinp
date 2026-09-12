import SwiftUI
import VoinpCore
import VoinpEngine

struct MenuBarContent: View {
    let model: AppModel

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
            ForEach(model.missingPermissions, id: \.self) { p in
                Button(label(for: p)) { model.requestPermission(p) }
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
        Button("設定ファイルを開く") { openConfigDirectory() }
        Button("Voinp を終了") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(for p: SessionError.Permission) -> String {
        switch p {
        case .microphone:    "マイクを許可する…"
        case .accessibility: "アクセシビリティを許可する…"
        }
    }

    private func openConfigDirectory() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/voinp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
