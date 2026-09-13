import CFNetwork
import Foundation
import VoinpCore

/// 送信が実際にどこへ TCP 接続するかを、システムのプロキシ設定から求める。
///
/// **これが無いと到達範囲の保証に穴が空く。**
/// 宛先が `127.0.0.1` でも、システム設定や PAC で HTTP プロキシが入っていれば
/// 実際の通信相手はプロキシであり、書き起こしはそちらへ渡る。
/// 社用 Mac では珍しくない構成で、多くのアプリが見落とす。
/// 宛先ホストを分類するだけでは「Mac から出ない」を主張できない。
///
/// 経路を確定できない場合は**拒否する**（fail closed）。
/// PAC は URL ごとに結果が変わりうるし、評価自体にネットワークアクセスが
/// 要ることすらある。「たぶん直結だろう」で送るのが最も危うい。
public struct ProxyResolver: Sendable {

    public enum Route: Equatable, Sendable {
        /// プロキシを経由しない。宛先の分類だけで判断してよい。
        case direct
        /// 経由するプロキシのホスト名。
        case proxied([String])
        /// 経路を判定できない。送信してはいけない。
        case undeterminable
        /// PAC の評価が要る。`resolve` は CFNetwork に触らないので、
        /// 取得と評価は呼び出し側 (`route`) に任せる。
        case needsPAC(URL)
    }

    /// CFNetwork の定数は `CFString` なので、`switch` で使えるよう文字列にしておく。
    enum Key {
        static let type = kCFProxyTypeKey as String
        static let host = kCFProxyHostNameKey as String
        static let none = kCFProxyTypeNone as String
        static let http = kCFProxyTypeHTTP as String
        static let https = kCFProxyTypeHTTPS as String
        static let socks = kCFProxyTypeSOCKS as String
        static let ftp = kCFProxyTypeFTP as String
        static let pacURL = kCFProxyTypeAutoConfigurationURL as String
        static let pacURLValue = kCFProxyAutoConfigurationURLKey as String
        static let pacScript = kCFProxyTypeAutoConfigurationJavaScript as String
    }

    public init() {}

    public func route(for url: URL) async -> Route {
        guard let settings = CFNetworkCopySystemProxySettings()?
            .takeRetainedValue() as? [AnyHashable: Any]
        else {
            // 設定そのものが読めない。直結と決めつけない。
            return .undeterminable
        }
        guard let raw = CFNetworkCopyProxiesForURL(url as CFURL, settings as CFDictionary)
            .takeRetainedValue() as? [[AnyHashable: Any]]
        else { return .undeterminable }

        switch Self.resolve(raw) {
        case .direct: return .direct
        case .proxied(let hosts): return .proxied(hosts)
        case .undeterminable: break
        case .needsPAC(let pacURL):
            // **PAC は評価する。** 「判定できないから拒否」で済ませると、
            // PAC を配る社内 Mac ではアプリが一切通信できなくなる。
            // 仕様 (docs/06-privacy.md 手順 7) が拒否と定めているのは
            // 「評価に失敗した / 結果が解釈できない」場合であって、
            // 評価しないことではない。
            return await Self.evaluate(pacURL: pacURL, target: url)
        }
        return .undeterminable
    }

    /// PAC を取得して評価し、この URL に適用される経路を得る。
    ///
    /// **PAC の取得は `EgressGate` を通らない。** 判定材料を集める通信が
    /// 判定を必要とする循環になるため。ここを通るのは PAC ファイルの取得だけで、
    /// 書き起こしや発話内容は一切含まれない
    /// （対象 URL も送られず、落としたスクリプトをローカルで評価するだけ）。
    static func evaluate(pacURL: URL, target: URL,
                         timeout: Duration = .seconds(5)) async -> Route {
        await withTaskGroup(of: Route.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Route, Never>) in
                    let box = ResultBox(continuation)
                    var context = CFStreamClientContext(
                        version: 0,
                        info: Unmanaged.passRetained(box).toOpaque(),
                        retain: nil, release: nil, copyDescription: nil)

                    let source = CFNetworkExecuteProxyAutoConfigurationURL(
                        pacURL as CFURL, target as CFURL, voinpPACCallback, &context)

                    // **専用の run loop で回す。** 呼び出し元のスレッドに
                    // run loop がある保証はなく、あっても回してもらえるとは限らない。
                    // CFRunLoopSource は Sendable ではないので、箱に入れて渡す。
                    let carrier = SourceBox(source)
                    let thread = Thread {
                        let mode = CFRunLoopMode.defaultMode
                        let s = carrier.source
                        CFRunLoopAddSource(CFRunLoopGetCurrent(), s, mode)
                        CFRunLoopRunInMode(mode, 10, false)
                        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, mode)
                    }
                    thread.stackSize = 1 << 19
                    thread.start()
                }
            }
            // PAC サーバーが応答しないまま入力が止まるのを避ける。
            // 期限切れは「判定できない」＝拒否。直結とみなさない。
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .undeterminable
            }
            let first = await group.next() ?? .undeterminable
            group.cancelAll()
            return first
        }
    }

    /// `CFRunLoopSource` を専用スレッドへ渡すための箱。
    /// CFNetwork が返す source は 1 つのスレッドでしか回さないので安全。
    final class SourceBox: @unchecked Sendable {
        let source: CFRunLoopSource
        init(_ source: CFRunLoopSource) { self.source = source }
    }

    /// `CheckedContinuation` を CFNetwork の callback 側へ渡すための箱。
    /// 二重 resume は即クラッシュなので、一度だけ通す。
    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Route, Never>?

        init(_ c: CheckedContinuation<Route, Never>) { continuation = c }

        func finish(_ route: Route) {
            lock.lock()
            guard let c = continuation else { lock.unlock(); return }
            continuation = nil
            lock.unlock()
            c.resume(returning: route)
        }
    }


    /// `CFNetworkCopyProxiesForURL` の戻りを解釈する。
    /// CFNetwork に触らない純粋関数なので、テストから直接叩ける。
    static func resolve(_ entries: [[AnyHashable: Any]]) -> Route {
        // 空配列は「判定できなかった」とみなす。直結なら kCFProxyTypeNone が 1 件返る。
        guard !entries.isEmpty else { return .undeterminable }

        var hosts: [String] = []
        for entry in entries {
            guard let type = entry[Key.type] as? String else { return .undeterminable }

            switch type {
            case Key.none:
                continue

            case Key.pacURL:
                // PAC は評価しないと送信先が分からない。取得と評価は route が行う。
                // **値は NSURL で来る。** 実機で確認した。
                // `as? String` だけで書いていたら常に失敗し、
                // PAC を配る環境で通信が全部止まった。文字列の場合も一応受ける。
                let value = entry[Key.pacURLValue]
                guard let u = (value as? URL)
                    ?? (value as? String).flatMap({ URL(string: $0) })
                else { return .undeterminable }
                return .needsPAC(u)

            case Key.pacScript:
                // インラインのスクリプトは扱わない（社内配布では URL 形式が普通）。
                // 解釈できないものを直結とみなさず、拒否側へ倒す。
                return .undeterminable

            case Key.http, Key.https, Key.socks, Key.ftp:
                guard let host = entry[Key.host] as? String, !host.isEmpty
                else { return .undeterminable }
                hosts.append(host)

            default:
                // 知らない種類が来たら、安全側に倒す。
                return .undeterminable
            }
        }

        return hosts.isEmpty ? .direct : .proxied(hosts)
    }
}

/// PAC 評価の完了コールバック。
///
/// **トップレベルに置くこと。** C の関数ポインタへ渡すクロージャは
/// コンテキストを捕まえられず、型の中に書くと暗黙の `Self` 参照で
/// コンパイラごと落ちた（signal 6）。
private func voinpPACCallback(_ info: UnsafeMutableRawPointer,
                              _ proxies: CFArray,
                              _ error: CFError?) {
    let box = Unmanaged<ProxyResolver.ResultBox>.fromOpaque(info).takeRetainedValue()
    guard error == nil, let list = proxies as? [[AnyHashable: Any]]
    else { return box.finish(.undeterminable) }

    // 評価結果にさらに PAC が出てきたら打ち切る（無限後退を避ける）。
    switch ProxyResolver.resolve(list) {
    case .direct: box.finish(.direct)
    case .proxied(let hosts): box.finish(.proxied(hosts))
    case .undeterminable, .needsPAC: box.finish(.undeterminable)
    }
}
