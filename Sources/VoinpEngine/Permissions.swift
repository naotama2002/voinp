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

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static func missingPermissions() -> [SessionError.Permission] {
        var missing: [SessionError.Permission] = []
        if microphoneStatus != .authorized { missing.append(.microphone) }
        if !isAccessibilityTrusted { missing.append(.accessibility) }
        return missing
    }

    public enum SettingsPane: String {
        case accessibility = "Privacy_Accessibility"
        case microphone = "Privacy_Microphone"

        public var url: URL {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
        }
    }
}
