import SwiftUI
import VoinpCore
import VoinpEngine

/// 初回起動時のセットアップウィザード。
///
/// `LSUIElement` のアプリは起動しても画面に何も出ないため、
/// メニューバーのアイコンに気づけない。**自分から出す**必要がある。
public struct SetupView: View {
    let model: AppModel
    let onFinish: () -> Void
    @State private var step: Step = .welcome

    public init(model: AppModel, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
    }

    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, speechModel, ready

        var title: String {
            switch self {
            case .welcome: "ようこそ"
            case .microphone: "マイク"
            case .accessibility: "アクセシビリティ"
            case .speechModel: "音声モデル"
            case .ready: "準備完了"
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            Divider()
            footer
        }
        .frame(width: 560, height: 420)
        .task { await model.refreshModelReadiness() }
        .onChange(of: model.missingPermissions) { advanceIfSatisfied() }
        .onChange(of: model.modelReadiness) { advanceIfSatisfied() }
    }

    // MARK: - 各部

    private var header: some View {
        HStack(spacing: 14) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(for: s))
                        .frame(width: 8, height: 8)
                    Text(s.title)
                        .font(.system(size: 11))
                        .foregroundStyle(s == step ? .primary : .secondary)
                }
                if s != .ready { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func color(for s: Step) -> Color {
        if isSatisfied(s) { return .green }
        return s == step ? .accentColor : .secondary.opacity(0.35)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            step(icon: "mic.circle.fill",
                 title: "Voinp へようこそ",
                 body: """
                 ホットキーを押しながら話すと、書き起こしたテキストが
                 いま使っているアプリに入力されます。

                 音声認識はこの Mac の中だけで行われ、
                 音声が外部に送信されることはありません。

                 使い始めるまでに、権限を 2 つと音声モデルの準備が必要です。
                 """)

        case .microphone:
            permissionStep(
                .microphone,
                icon: "mic.fill",
                title: "マイクの使用を許可してください",
                body: "音声を認識するために必要です。音声はこの Mac 上でのみ処理され、保存されません。")

        case .accessibility:
            permissionStep(
                .accessibility,
                icon: "hand.tap.fill",
                title: "アクセシビリティを許可してください",
                body: """
                ホットキーの検出と、他のアプリへのテキスト入力に必要です。

                システム設定が開いたら、リストから Voinp を探して
                スイッチをオンにしてください。
                """)

        case .speechModel:
            modelStep

        case .ready:
            readyStep
        }
    }

    private func step(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.tint)
            Text(title).font(.title2).bold()
            Text(body).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionStep(_ p: SessionError.Permission,
                                icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.tint)
                if !model.missingPermissions.contains(p) {
                    Label("許可済み", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.system(size: 13, weight: .medium))
                }
            }
            Text(title).font(.title2).bold()
            Text(body).font(.system(size: 13)).foregroundStyle(.secondary)

            if model.missingPermissions.contains(p) {
                HStack(spacing: 10) {
                    Button("許可する…") { model.requestPermission(p) }
                        .buttonStyle(.borderedProminent)
                    Button("システム設定を開く") { model.openSettings(for: p) }
                }
                Text("許可すると自動的に次へ進みます。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 38)).foregroundStyle(.tint)
            Text("音声モデルを準備します").font(.title2).bold()
            Text("""
                 日本語を認識するためのモデルを macOS から取得します。
                 一度取得すれば、以降はオフラインでも動作します。
                 """)
                .font(.system(size: 13)).foregroundStyle(.secondary)

            switch model.modelReadiness {
            case .ready:
                Label("準備できました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 13, weight: .medium))
            case .unsupported(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.system(size: 13))
            default:
                if model.isDownloadingModel {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.hasMeaningfulProgress {
                            ProgressView(value: model.modelProgress ?? 0) {
                                Text("取得中… \(Int((model.modelProgress ?? 0) * 100))%")
                                    .font(.system(size: 12))
                            }
                        } else {
                            // Speech の資産ダウンロードは進捗を返さないことがある
                            // （実測で fractionCompleted が 0.0 のまま完了した）。
                            // 0% のバーを出すと固まったように見えるので不定表示にする。
                            ProgressView {
                                Text("取得中…").font(.system(size: 12))
                            }
                            .progressViewStyle(.linear)
                        }
                        Text("ネットワーク環境によっては数分かかることがあります。")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: 320)
                } else {
                    Button("モデルを取得") { Task { await model.downloadModel() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 38)).foregroundStyle(.green)
            Text("準備ができました").font(.title2).bold()

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("**\(model.settings.hotkey.binding)** を押しながら話してください")
                } icon: { Image(systemName: "keyboard") }
                Label {
                    Text("離すと、書き起こしたテキストが入力されます")
                } icon: { Image(systemName: "text.cursor") }
                Label {
                    Text("メニューバーの \(Image(systemName: "mic")) からいつでも設定できます")
                } icon: { Image(systemName: "menubar.arrow.up.rectangle") }
            }
            .font(.system(size: 13))

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("戻る") { move(-1) }
            }
            Spacer()
            if step == .ready {
                Button("はじめる") {
                    model.hasSeenSetup = true
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                // 三項演算子で ButtonStyle を切り替えられないので分岐する
                if isSatisfied(step) {
                    Button("次へ") { move(1) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("あとで") { move(1) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 進行

    private func isSatisfied(_ s: Step) -> Bool {
        switch s {
        case .welcome: true
        case .microphone: !model.missingPermissions.contains(.microphone)
        case .accessibility: !model.missingPermissions.contains(.accessibility)
        case .speechModel: model.modelReadiness == .ready
        case .ready: false
        }
    }

    /// いまのステップが満たされたら自動で次へ。
    /// ユーザーが許可した直後に手で「次へ」を押させない。
    private func advanceIfSatisfied() {
        guard step != .ready, isSatisfied(step) else { return }
        withAnimation { move(1) }
    }

    private func move(_ delta: Int) {
        let next = max(0, min(Step.allCases.count - 1, step.rawValue + delta))
        step = Step(rawValue: next) ?? step
    }
}
