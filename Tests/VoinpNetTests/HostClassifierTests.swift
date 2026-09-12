import Testing
import VoinpCore
@testable import VoinpNet

@Suite("ホストの分類")
struct HostClassifierTests {

    @Test("loopback", arguments: ["127.0.0.1", "127.1.2.3", "::1"])
    func loopback(_ address: String) {
        #expect(HostClassifier.classifyAddress(address) == .loopback)
    }

    @Test("プライベートネットワーク", arguments: [
        "10.0.0.1", "192.168.1.50", "172.16.0.1", "172.31.255.254", "169.254.1.1",
        "fc00::1", "fe80::1",
    ])
    func privateNetwork(_ address: String) {
        #expect(HostClassifier.classifyAddress(address) == .privateNetwork)
    }

    @Test("公開インターネット", arguments: ["8.8.8.8", "1.1.1.1", "172.32.0.1", "2606:4700::1111"])
    func publicInternet(_ address: String) {
        #expect(HostClassifier.classifyAddress(address) == .publicInternet)
    }

    @Test("172.16/12 の境界を正しく判定する")
    func privateRangeBoundaries() {
        #expect(HostClassifier.classifyAddress("172.15.255.255") == .publicInternet)
        #expect(HostClassifier.classifyAddress("172.16.0.0") == .privateNetwork)
        #expect(HostClassifier.classifyAddress("172.31.255.255") == .privateNetwork)
        #expect(HostClassifier.classifyAddress("172.32.0.0") == .publicInternet)
    }

    @Test("リテラル IP は DNS を引かずに分類できる")
    func literalsSkipDNS() {
        #expect(HostClassifier.classifyLiteral("127.0.0.1") == .loopback)
        #expect(HostClassifier.classifyLiteral("::1") == .loopback)
        #expect(HostClassifier.classifyLiteral("example.com") == nil, "ホスト名は解決が要る")
    }
}
