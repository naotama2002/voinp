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

    /// マイクが実際に使えるか。
    ///
    /// `authorizationStatus` はプロセス内でキャッシュされることがあり、
    /// システム設定で許可してもアプリを再起動するまで古い値を返す
    /// （macOS が「終了して再度開く」を促すのはこのため）。
    ///
    /// `AVAudioEngine.start()` は判定に使えない。**拒否されていても成功し、
    /// 無音のバッファを返す**ため、成功しても許可の証明にならない。
    /// `AVCaptureDeviceInput` の生成は未許可なら throw するので、
    /// こちらを機能的な判定に使う。
    public static func canOpenMicrophone() -> Bool {
        guard let device = AVCaptureDevice.default(for: .audio) else { return false }
        do {
            _ = try AVCaptureDeviceInput(device: device)
            return true
        } catch {
            return false
        }
    }

    /// マイクが使えるか。
    ///
    /// **まず副作用のない `authorizationStatus` を見る。** 許可されていればそれで終わり。
    /// そうでないときだけ実地検証に落ちる（キャッシュが古い可能性があるため）。
    /// 呼ばれるのは権限確認のタイミングだけなので、実地検証が走る頻度は低い。
    public static var isMicrophoneUsable: Bool {
        if microphoneStatus == .authorized { return true }
        return canOpenMicrophone()
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
    public static func requestMicrophoneIfPossible() async -> MicrophoneRequestOutcome {
        if isMicrophoneUsable { return .granted }
        switch microphoneStatus {
        case .notDetermined:
            return await requestMicrophone() ? .granted : .promptShown
        default:
            return .mustUseSettings
        }
    }
}
