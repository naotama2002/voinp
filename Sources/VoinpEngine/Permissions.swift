import ApplicationServices
import AVFoundation
import CoreGraphics
import VoinpCore

/// TCC 権限の問い合わせと誘導。
///
/// 注意: `AXIsProcessTrusted()` の値はプロセスごとに初回問い合わせ時点でキャッシュされる。
/// オンボーディング表示中はポーリングすること (アプリ再起動を要求しないため)。
public enum Permissions {

    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// システム設定を開くプロンプトを出しつつ問い合わせる。
    ///
    /// `kAXTrustedCheckOptionPrompt` は `var` としてインポートされるため、
    /// Swift 6 strict concurrency では「shared mutable state」として拒否される。
    /// 値は安定しているので文字列リテラルで指定する。
    @discardableResult
    public static func requestAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 合成キーイベントを post できるか。アクセシビリティ権限に紐づく。
    public static var canPostEvents: Bool { CGPreflightPostEventAccess() }

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// マイクが使えるか。
    ///
    /// **アクセシビリティと違い、機能判定という逃げ道がない。**
    /// 一度試して確認した結果:
    ///   - `AVAudioEngine.start()` は拒否されていても成功し、無音を返す（判定不能）
    ///   - `AVCaptureDeviceInput` の生成は未許可なら throw するが、
    ///     システム設定で許可しても**再起動するまで throw し続ける**
    ///
    /// つまり TCC の判断は音声サブシステム側で握られており、
    /// プロセス内から現在の状態を知る方法がない。
    /// Zoom など他のアプリでも「許可したのに再起動するまで使えない」のは同じ理由。
    ///
    /// したがって `authorizationStatus` を素直に使い、
    /// 再起動が必要な場面ではそう案内する（`requiresRestartToApply`）。
    public static var isMicrophoneUsable: Bool {
        microphoneStatus == .authorized
    }

    /// 許可の反映にアプリの再起動が要る状態か。
    ///
    /// 一度拒否されると、アプリ内ダイアログは二度と出せず
    /// システム設定で許可してもらうしかない。その場合は再起動が必須になる。
    public static var microphoneRequiresRestart: Bool {
        microphoneStatus == .denied || microphoneStatus == .restricted
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static func missingPermissions() -> [SessionError.Permission] {
        var missing: [SessionError.Permission] = []
        if !isMicrophoneUsable { missing.append(.microphone) }
        if !isAccessibilityTrusted { missing.append(.accessibility) }
        return missing
    }

    public enum SettingsPane: String {
        case accessibility = "Privacy_Accessibility"
        case microphone = "Privacy_Microphone"

        /// macOS 26 の設定は ExtensionKit 化されている。
        /// 旧 `com.apple.preference.security` も互換で残っているが、
        /// 目的のセクションに正しく飛ばないことがあるので新しい方を使う
        /// （`SecurityPrivacyExtension.appex` の bundle id を実機で確認済み）。
        public var url: URL {
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(rawValue)")!
        }
    }

    /// マイク許可を求めるときに何が起きるか。UI の分岐に使う。
    public enum MicrophoneRequestOutcome: Sendable {
        case granted
        /// OS のダイアログを出せた。ユーザーの応答待ち。
        case promptShown
        /// 既に拒否済みでダイアログは出ない。設定を開くしかない。
        case mustUseSettings
    }

    /// 状態に応じて「ダイアログを出す」か「設定を開くしかない」かを返す。
    ///
    /// 未決定ならダイアログが出るので、**そこで設定も同時に開いてはいけない**
    /// （ダイアログの上に設定画面が被さって何が起きたか分からなくなる）。
    /// マイク許可を求める。
    ///
    /// **未決定のうちにアプリ内ダイアログで許可してもらうのが唯一の「再起動不要」経路。**
    /// 一度拒否されるとシステム設定経由しかなく、そこからは再起動が必須になる。
    /// だからウィザードでは、この経路を最優先で通す。
    public static func requestMicrophoneIfPossible() async -> MicrophoneRequestOutcome {
        switch microphoneStatus {
        case .authorized: return .granted
        case .notDetermined:
            return await requestMicrophone() ? .granted : .promptShown
        default:
            return .mustUseSettings
        }
    }
}
