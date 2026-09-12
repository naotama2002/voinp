import Foundation

/// 1 回のディクテーションセッションが失敗した理由。HUD に出す粒度。
public enum SessionError: Error, Equatable, Sendable {
    /// パスワード欄にフォーカスしている
    case secureInputActive
    /// マイク / アクセシビリティが未許可
    case permissionMissing(Permission)
    /// 音声入力を開始できなかった
    case audioUnavailable(VoinpError)
    /// 認識エンジンが失敗した
    case transcriptionFailed(VoinpError)
    /// 発話が短すぎる (`minRecordingMs` 未満)
    case tooShort
    /// 挿入に失敗した。テキストはペーストボードに退避済み
    case insertionFailed(VoinpError)
    /// 修飾キーが離されないまま上限時間を超えた。テキストはペーストボードに退避済み
    case modifiersStuck
    /// 設定が読めないため通信を停止している
    case misconfigured(String)

    public enum Permission: Equatable, Sendable {
        case microphone
        case accessibility
    }

    /// テキストがペーストボードに退避されているか。HUD の文言を変えるのに使う。
    public var textIsOnPasteboard: Bool {
        switch self {
        case .insertionFailed, .modifiersStuck: true
        default: false
        }
    }
}
