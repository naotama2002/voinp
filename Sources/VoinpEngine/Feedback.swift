import AppKit
import VoinpCore

/// 録音の開始・終了などを音で知らせる。
///
/// 独自の音源は持たず、システム音を使う。配布サイズも増えず、
/// ユーザーが既に知っている音なので意味も伝わりやすい。
@MainActor
public enum FeedbackPlayer {
    public static func play(_ feedback: Feedback, enabled: Bool) {
        guard enabled, let name = soundName(for: feedback) else { return }
        NSSound(named: name)?.play()
    }

    private static func soundName(for f: Feedback) -> NSSound.Name? {
        switch f {
        case .start:  NSSound.Name("Tink")    // 短い開始音
        case .stop:   NSSound.Name("Pop")     // 確定
        case .cancel: NSSound.Name("Funk")    // 取りやめ
        case .error:  NSSound.Name("Basso")   // 失敗
        }
    }
}
