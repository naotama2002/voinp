import Foundation
import Testing
@testable import VoinpCore

/// API キーが接続先にひも付いていること。
///
/// レビュー指摘 1「接続先を変更すると、以前の API キーが新しいサーバーへ送られます」
/// に対応する。以前は固定の口座名 1 つに保存しており、
/// キー欄を空にして別ホストへ接続テストしても保存済みのキーが付与されていた。
@Suite("API キーは接続先ごとに分かれること")
struct CredentialScopeTests {

    /// **これが本題。** ホストが違えば口座名も違い、
    /// 一方のキーがもう一方へ渡ることが構造的に起きない。
    @Test("ホストが違えば別の口座になる")
    func differentHostsDifferentAccounts() {
        let a = CredentialRef.openAICompatible(host: "llm-a.example.com")
        let b = CredentialRef.openAICompatible(host: "llm-b.example.com")
        #expect(a != nil)
        #expect(b != nil)
        #expect(a != b, "接続先が変われば資格情報も変わること")
    }

    @Test("同じホストなら同じ口座になる")
    func sameHostSameAccount() {
        #expect(CredentialRef.openAICompatible(host: "llm.example.com")
                == CredentialRef.openAICompatible(host: "llm.example.com"))
    }

    /// ホスト名の大小や前後の空白で別物にならないこと
    /// （同じサーバーなのに毎回キーを入れ直す羽目になる）。
    @Test("大小と空白を無視して同一視する")
    func hostIsCanonicalized() {
        #expect(CredentialRef.openAICompatible(host: "  LLM.Example.COM ")
                == CredentialRef.openAICompatible(host: "llm.example.com"))
    }

    @Test("ホストが取れないなら資格情報を作らない")
    func noHostNoCredential() {
        #expect(CredentialRef.openAICompatible(host: nil) == nil)
        #expect(CredentialRef.openAICompatible(host: "") == nil)
        #expect(CredentialRef.openAICompatible(host: "   ") == nil)
        #expect(CredentialRef.openAICompatible(urlString: "") == nil)
    }

    @Test("URL 文字列からもホストで引ける")
    func fromURLString() {
        let fromURL = CredentialRef.openAICompatible(urlString: "https://llm.example.com/v1")
        #expect(fromURL == CredentialRef.openAICompatible(host: "llm.example.com"))
    }

    /// 設定欄には `localhost:1234` のようにスキーム無しで書ける。
    /// それで口座が変わると、探索時と校正時で別の口座を見に行ってしまう。
    @Test("スキームが無い入力でもホストを取り出す")
    func schemelessInput() {
        #expect(CredentialRef.openAICompatible(urlString: "localhost:1234")
                == CredentialRef.openAICompatible(host: "localhost"))
        #expect(CredentialRef.openAICompatible(urlString: "llm.example.com/v1")
                == CredentialRef.openAICompatible(host: "llm.example.com"))
    }

    /// ポートが違うだけなら同じホストとして扱う（同一マシン上の別サーバー）。
    /// ここは判断の余地があるが、`localhost:1234` と `localhost:11434` で
    /// キーを入れ直させるほうが実害が大きいと考えてこうしている。
    @Test("ポートの違いは口座を分けない")
    func portDoesNotSplitAccount() {
        #expect(CredentialRef.openAICompatible(urlString: "http://localhost:1234")
                == CredentialRef.openAICompatible(urlString: "http://localhost:11434"))
    }
}
