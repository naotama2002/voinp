import AppKit
import SwiftUI
import VoinpCore
import VoinpEngine

/// アプリのエントリポイント。実行ターゲットの main.swift から呼ぶ。
public enum VoinpRoot {
    /// `App` の `init()` は引数を取れないため、合成ルートから渡された依存をここで受け渡す。
    @MainActor static var dependencies = Dependencies.base()
    @MainActor static var model: AppModel?

    @MainActor
    public static func run(_ deps: Dependencies) {
        dependencies = deps
        VoinpApp.main()
    }
}

/// 起動処理は `applicationDidFinishLaunching` で行う。
///
/// `MenuBarExtra` のラベルに付けた `onAppear` は発火が保証されず、
/// 実際に一度も呼ばれずコーディネータもホットキーも起動しなかった。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            Log.session.info("applicationDidFinishLaunching")
            VoinpRoot.model?.start()
        }
    }
}

struct VoinpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let m = AppModel(dependencies: VoinpRoot.dependencies)
        _model = State(initialValue: m)
        VoinpRoot.model = m
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
