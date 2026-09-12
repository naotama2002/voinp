import SwiftUI
import VoinpCore
import VoinpEngine

struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        Text(model.privacyHeadline)
        Divider()

        if !model.missingPermissions.isEmpty {
            ForEach(model.missingPermissions, id: \.self) { p in
                Button(label(for: p)) { open(p) }
            }
            Divider()
        }

        if model.dependencies.supportsRefinement {
            Text("校正: 利用可能")
        } else {
            Text("校正: なし (オフライン版)")
        }

        Divider()
        Button("Voinp を終了") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(for p: SessionError.Permission) -> String {
        switch p {
        case .microphone:    "マイクを許可する…"
        case .accessibility: "アクセシビリティを許可する…"
        }
    }

    private func open(_ p: SessionError.Permission) {
        switch p {
        case .microphone:
            NSWorkspace.shared.open(Permissions.SettingsPane.microphone.url)
        case .accessibility:
            Permissions.requestAccessibility()
            NSWorkspace.shared.open(Permissions.SettingsPane.accessibility.url)
        }
    }
}
