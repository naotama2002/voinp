import Foundation
import Testing
@testable import VoinpNet

/// 実機のプロキシ設定を表示するだけの診断。
///
/// **既定では走らせない。** 結果がそのマシンのシステム設定に依存するため、
/// CI でも他人の環境でも同じ答えにならない。
/// 「社内 Mac で校正が急に通らなくなった」ときの切り分けに使う:
/// `swift test --filter PacProbeTests` で経路が出る。
@Suite("PAC 実機診断", .disabled("実機のシステム設定に依存するため既定では走らせない"))
struct PacProbeTests {
    @Test("宛先ごとの経路を表示する")
    func dump() async {
        for s in ["https://ai4-api.dev.cybozu.xyz/v1/models",
                  "http://127.0.0.1:1234/v1/models",
                  "http://localhost:11434/v1/models",
                  "https://api.openai.com/v1/models"] {
            let route = await ProxyResolver().route(for: URL(string: s)!)
            print(">>> \(s) → \(route)")
        }
    }
}
