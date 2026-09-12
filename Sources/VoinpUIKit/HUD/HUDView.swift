import SwiftUI
import VoinpCore

struct HUDView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                Text(statusText).font(.system(size: 12, weight: .medium))
                Spacer()
                if model.phase.isListening {
                    Text("esc でキャンセル")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            WaveformView(level: model.level, active: model.phase.isListening)
                .frame(height: 22)

            if model.settings.ui.hudShowText, !model.snapshot.fullText.isEmpty {
                // 確定分と暫定分を描き分ける。暫定は次の結果で丸ごと置き換わる。
                //
                // 喋り続けると必ず幅を超えるので、**末尾（最新）が見えるように切る**。
                // 先頭を残すと、いま喋っている内容が見えなくなって役に立たない。
                Text("\(model.snapshot.committed)\(Text(model.snapshot.volatileTail).foregroundStyle(.secondary))")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(Self.maxLines, reservesSpace: false)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)   // 高さは内容に合わせて伸びる
    }

    static let width: CGFloat = 520
    static let maxLines = 6

    private var icon: String {
        switch model.phase {
        case .listening: "mic.fill"
        case .finalizing, .refining: "ellipsis"
        case .awaitingModifierRelease: "hand.raised.fill"
        case .inserting: "text.cursor"
        case .installingModel: "arrow.down.circle"
        case .failed: "exclamationmark.triangle.fill"
        default: "mic"
        }
    }

    private var tint: Color {
        if case .failed = model.phase { return .orange }
        return model.phase.isListening ? .red : .secondary
    }

    private var statusText: String {
        switch model.phase {
        case .arming: "準備中…"
        case .listening: "録音中"
        case .finalizing: "認識中…"
        case .refining: "整形中…"
        case .awaitingModifierRelease: "修飾キーを離してください"
        case .inserting: "挿入中…"
        case .installingModel(let p): "モデルを取得中… \(Int(p * 100))%"
        case .failed(let e): Self.message(for: e)
        case .idle: "待機中"
        }
    }

    static func message(for error: SessionError) -> String {
        switch error {
        case .secureInputActive: "パスワード欄にフォーカスしています"
        case .permissionMissing(.microphone): "マイクの許可が必要です"
        case .permissionMissing(.accessibility): "アクセシビリティの許可が必要です"
        case .tooShort: "短すぎます"
        case .modifiersStuck: "⌘V で貼り付けてください"
        case .insertionFailed: "挿入できませんでした。⌘V で貼り付けてください"
        case .audioUnavailable: "マイクを使用できません"
        case .transcriptionFailed: "認識に失敗しました"
        case .misconfigured: "設定エラー"
        }
    }
}

private struct WaveformView: View {
    let level: Float
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<28, id: \.self) { i in
                Capsule()
                    .fill(active ? Color.red.opacity(0.85) : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: height(i))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func height(_ i: Int) -> CGFloat {
        guard active else { return 3 }
        // 中央ほど大きく振れるように見せる
        let center = 1 - abs(Double(i) - 13.5) / 13.5
        let amp = CGFloat(min(1, level * 8)) * CGFloat(center)
        return max(3, amp * 22)
    }
}
