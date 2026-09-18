import Foundation

/// 設定に書かれた接続先を WebSocket の URL にする。
///
/// **本体の設定は形がまちまち。** `https` のことも `wss` のこともあり、
/// `/realtime` が付いていたりいなかったり、クエリが先に付いていたりする。
/// 比較ツールのために書き直させないので、どの形でも受ける。
///
/// **文字列の連結で組み立てない。** 素朴に `+= "/realtime"` と書いたら、
/// クエリの後ろに付いて壊れた:
///
///     入力: .../openai/v1?intent=transcription
///     出力: .../openai/v1?intent=transcription/realtime   ← 接続できない
///
/// `URLComponents` でパスとクエリを分けて扱う。
///
/// `?intent=transcription` は **Azure でも必須**。
/// 付けない URL は 101 が返らない（実測で確認済み）。
public func realtimeURL(from configured: String) -> URL? {
    let trimmed = configured.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    let swapped = trimmed
        .replacingOccurrences(of: "https://", with: "wss://")
        .replacingOccurrences(of: "http://", with: "ws://")
    guard var components = URLComponents(string: swapped) else { return nil }

    // パス。末尾のスラッシュを落としてから /realtime を足す。
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    if !path.hasSuffix("/realtime") { path += "/realtime" }
    components.path = path

    // クエリ。すでに intent があれば触らない。
    var items = components.queryItems ?? []
    if !items.contains(where: { $0.name == "intent" }) {
        items.append(URLQueryItem(name: "intent", value: "transcription"))
    }
    components.queryItems = items

    return components.url
}
