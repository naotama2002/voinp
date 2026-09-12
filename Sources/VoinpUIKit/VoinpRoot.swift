import AppKit
import SwiftUI
import VoinpCore
import VoinpEngine

/// アプリのエントリポイント。実行ターゲットの main.swift から呼ぶ。
public enum VoinpRoot {
    /// `App` の `init()` は引数を取れないため、合成ルートから渡された依存を
    /// ここで受け渡す。`run` は main actor 上で 1 度しか呼ばれない。
    @MainActor static var dependencies = Dependencies.base()

    @MainActor
    public static func run(_ deps: Dependencies) {
        dependencies = deps
        VoinpApp.main()
    }
}

struct VoinpApp: App {
    @State private var model = AppModel(dependencies: VoinpRoot.dependencies)

    init() {
        // LSUIElement が既に含意するが、素のバイナリを直接起動する開発時に効く。
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}
