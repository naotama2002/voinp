import Foundation

/// 設定に書かれた接続先を WebSocket の URL にする。
///
/// **本体の設定は `https` のことも `wss` のこともある。**
/// 比較ツールのために書き直させない。voinp でクラウド認識を設定してあれば、
/// その `endpointURL` をそのまま渡せば通るようにする。
///
/// `?intent=transcription` は **Azure でも必須**。
/// 付けない URL は 101 が返らない（実測で確認済み）。
public func realtimeURL(from configured: String) -> URL? {
    var text = configured.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    text = text.replacingOccurrences(of: "https://", with: "wss://")
               .replacingOccurrences(of: "http://", with: "ws://")
    while text.hasSuffix("/") { text.removeLast() }
    if !text.contains("/realtime") { text += "/realtime" }
    if !text.contains("intent=") { text += "?intent=transcription" }
    return URL(string: text)
}
