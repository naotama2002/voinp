import SwiftUI

/// 挿入前に確認して直す面。
///
/// **HUD とは別のウィンドウである。** HUD は `canBecomeKey: false` で
/// 作ってあり（挿入先を見失わないため）、そこを条件分岐で覆すと
/// 元に戻すのが難しくなる。編集はこちらで完結させる。
struct EditView: View {
    @Bindable var content: EditContent
    let onApply: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            TextEditor(text: $content.text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .focused($focused)

            footer
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 200)
        // 開いた直後に打てないと、確認のための一拍が丸ごと無駄になる。
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil.and.scribble")
                .foregroundStyle(.secondary)
            Text(content.destination.map { "\($0) に挿入します" } ?? "挿入前の確認")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(content.text.count) 文字")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            Button("破棄", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            // **⏎ 単独にはしない。** TextEditor の中では改行になる。
            Button("挿入") { onApply(content.text) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(content.text.isEmpty)
        }
    }
}
