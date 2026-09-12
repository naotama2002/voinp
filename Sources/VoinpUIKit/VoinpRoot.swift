import AppKit
import SwiftUI
import VoinpCore
import VoinpEngine

/// アプリのエントリポイント。実行ターゲットの main.swift から呼ぶ。
public enum VoinpRoot {
    /// `App` の `init()` は引数を取れないため、合成ルートから渡された依存をここで受け渡す。
    @MainActor static var dependencies = Dependencies.base()
    @MainActor static var model: AppModel?
    @MainActor static var setup: SetupWindowController?

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
            guard let model = VoinpRoot.model else { return }
            model.start()

            let setup = SetupWindowController(model: model)
            VoinpRoot.setup = setup
            model.presentSetup = { [weak setup] in setup?.show() }

            // LSUIElement のアプリは起動しても画面に何も出ないため、
            // メニューバーのアイコンに気づけない。**自分からウィザードを出す。**
            // 権限やモデルが揃っていなければ毎回出る（取り消された場合も自動で復帰する）。
            //
            // モデルの状態確認は非同期なので、**終わってから判定する**。
            // 先に判定すると modelReadiness が nil のまま「未準備」と誤判定し、
            // 完了済みでも毎回ウィザードが出てしまう。
            Task { @MainActor in
                await model.refreshModelReadiness()
                guard model.shouldPresentSetup else {
                    Log.session.info("セットアップ不要")
                    return
                }
                Log.session.info("セットアップを表示")
                setup.show()
            }
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
