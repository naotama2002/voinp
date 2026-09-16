import SwiftUI
import VoinpCore

/// 「音声をこの Mac の外へ出す」ことへの明示的な同意。
///
/// **これが旗印を降ろさずに済んでいる根拠。**
/// 旗印は「デフォルト起動状態では音声を外部に送信しない」であり、
/// そこから外れるにはユーザーの明示操作が要る、という形にしてある。
///
/// 出すのは設定ウィンドウ上のシート。別ウィンドウにはしない
/// （操作の起点が設定画面なので、そこに留めるのが素直）。
struct AudioEgressConsentSheet: View {
    let host: String
    let port: Int
    let operatorKind: String
    let refinementHost: String?
    /// 送信先の実際の到達範囲。**ホスト名から推測せず解決した値**。
    let reach: EgressClass?
    /// いまの上限。
    let currentCeiling: EgressClass
    let onConsent: () -> Void
    let onCancel: () -> Void

    /// 送信先が現在の上限を超えているか。
    ///
    /// **超えるときだけ、同意に「上限を広げること」を含める。**
    /// 別画面の知らないスイッチで黙って止めるのは保護ではなく罠になる
    /// （実際に「同意したのに動かない」を踏んだ）。
    private var wouldRaiseCeiling: Bool {
        guard let reach else { return false }
        return reach > currentCeiling
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    destination
                    whatIsSent
                    if wouldRaiseCeiling { ceilingChange }
                    whatChanges
                    caveat
                }
                .padding(20)
            }
            Divider()
            buttons
        }
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("この設定にすると、音声がこの Mac の外に出ます")
                    .font(.system(size: 15, weight: .semibold))
                Text("これまで Voinp は、音声をこの Mac の中だけで処理していました。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("送信先").font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                row("ホスト", "\(host):\(port)")
                row("到達範囲", reach?.displayName ?? "判定できませんでした")
                // **申告であることを隠さない。** アプリは検証していない。
                row("運用主体", operatorKind == "self-hosted"
                    ? "自社運用（あなたがそう設定しました。Voinp は検証していません）"
                    : "外部サービス（あなたがそう設定しました）")
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var whatIsSent: some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("送るもの", [
                "録音した音声そのもの（PCM）",
                "登録した用語ヒント（社内用語・製品名・人名）",
                refinementHost.map { "校正が有効なので、書き起こしたテキストも別途 \($0) へ" },
            ].compactMap { $0 }, symbol: "arrow.up.circle.fill", tint: .orange)

            labelled("送らないもの", [
                "画面の内容、他のアプリの情報",
                "利用統計・クラッシュレポート",
                "音声をディスクに保存することはありません。送信後は破棄します",
            ], symbol: "xmark.circle", tint: .secondary)
        }
    }

    private var whatChanges: some View {
        labelled("有効にすると、こう変わります", [
            "メニューバーのアイコンが変わり、音声が外に出る状態を常に示します",
            "録音中の表示に「クラウド」と送信先が出ます",
            "この確認の記録が config.json の privacy.audioEgress に残ります",
        ], symbol: "info.circle", tint: .secondary)
    }

    /// 上限も一緒に広がることを明示する。
    /// **何が変わるかを言わずに広げてはいけない。**
    @ViewBuilder
    private var ceilingChange: some View {
        if let reach {
            VStack(alignment: .leading, spacing: 6) {
                Label("送信の上限も広がります", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("この送信先は「\(reach.displayName)」です。"
                     + "いまの上限は「\(currentCeiling.displayName)」なので、"
                     + "同意すると上限が「\(reach.displayName)」まで広がります。")
                Text("上限はすべての通信に効くので、LLM 校正の送信先にも同じ範囲が適用されます。"
                     + "あとから 設定 › プライバシー で狭められます。")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var caveat: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("送信先のサーバーが音声をどう保存し、学習に使うかは Voinp からは確認できません。"
                 + "運用者の規約を確認してください。")
            Text("いつでも 設定 › 音声認識 で「この Mac で認識」に戻せます。"
                 + "戻すと、次に有効にするときにこの確認をもう一度表示します。")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack {
            Spacer()
            // **「同意する」を既定ボタンにしない。** Return の連打で通ってしまう。
            Button("音声を送信することに同意して有効にする", action: onConsent)
            Button("キャンセル", action: onCancel).keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(name).frame(width: 72, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func labelled(_ title: String, _ items: [String],
                          symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(tint)
                    Text(item).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
