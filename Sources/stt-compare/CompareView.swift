import STTCompare
import SwiftUI
import VoinpCore

/// 認識結果を横に並べる。
///
/// 見たいのは **同じ発話に対する差** なので、列の幅を揃えて
/// 同時に目に入るようにする。スクロールで行き来すると比べられない。
struct CompareView: View {
    let model: CompareModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            columns
            Divider()
            footer
        }
        .frame(minWidth: 1_100, minHeight: 560)
    }

    // MARK: - 上部

    private var header: some View {
        HStack(spacing: 14) {
            Button(model.isRecording ? "停止" : "録音開始") {
                Task { await model.toggle() }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.engines.isEmpty)

            if model.isRecording {
                Label("録音中", systemImage: "mic.fill").foregroundStyle(.red)
            }

            Spacer()

            // 同じ台本を読み上げて比べるための欄。
            // **その場で思いついた文を話すと、毎回条件が変わる。**
            TextField("読み上げる台本（任意）", text: Binding(
                get: { model.script }, set: { model.script = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)

            Button("結果をコピー") { model.copyResults() }
                .disabled(model.results.allSatisfy { $0.text.isEmpty })
        }
        .padding(12)
    }

    // MARK: - 列

    private var columns: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                if index > 0 { Divider() }
                column(result)
            }
        }
    }

    private func column(_ result: EngineResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(result.displayName).font(.system(size: 13, weight: .semibold))
                stateBadge(result.state)
                Spacer(minLength: 0)
            }

            // **レイテンシは 2 つ出す。** 体感の速さ（最初の文字まで）と
            // 待たされ方（停止から確定まで）は別の性質で、片方だけでは判断できない。
            HStack(spacing: 10) {
                latency("初出", result.firstTextMs)
                latency("確定", result.finalizeMs)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // 確定と暫定を見分けられるようにする。
                    // 暫定は次の結果で丸ごと置き換わるので、同じに見せると誤解を招く。
                    Text(result.committed)
                        .textSelection(.enabled)
                    if !result.volatile.isEmpty {
                        Text(result.volatile)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if case .failed(let why) = result.state {
                        Text(why)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stateBadge(_ state: EngineResult.State) -> some View {
        let (text, tint): (String, Color) = switch state {
        case .idle: ("待機", .secondary)
        case .connecting: ("接続中", .orange)
        case .listening: ("認識中", .green)
        case .finished: ("完了", .secondary)
        case .failed: ("失敗", .red)
        }
        return Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private func latency(_ label: String, _ ms: Int?) -> some View {
        HStack(spacing: 3) {
            Text(label)
            Text(ms.map { "\($0) ms" } ?? "—")
                .monospacedDigit()
                .foregroundStyle(ms == nil ? .tertiary : .primary)
        }
    }

    // MARK: - 下部

    private var footer: some View {
        HStack(spacing: 14) {
            // **音声がどこへ出るかを常に出す。** 3 ベンダーへ同時に送る道具なので、
            // 何が起きているか分からないまま使われる状態にしない。
            Label(model.egressSummary, systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Spacer()
            if let note = model.note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
