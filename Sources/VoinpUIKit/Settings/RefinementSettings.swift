import SwiftUI
import VoinpCore

struct RefinementSettings: View {
    let model: AppModel
    @State private var urlInput = ""
    @State private var apiKeyInput = ""
    @State private var promptInput = ""
    @State private var isProbing = false
    @State private var probeMessage: String?
    @State private var probeSucceeded = false
    @State private var models: [ModelInfo] = []

    var body: some View {
        Form {
            Section {
                Toggle("LLM で校正する", isOn: Binding(
                    get: { model.settings.refinement.enabled },
                    set: { v in model.update { $0.refinement.enabled = v } }))
                Text("フィラー（「えー」「あのー」）の除去や、明らかな誤変換の修正を行います。音声は送信しません。送るのは書き起こしたテキストだけです。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if model.settings.refinement.enabled {
                connectionSection
                promptSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            urlInput = model.settings.refinement.openaiCompatible.baseURL
            promptInput = model.settings.refinement.prompt
        }
    }

    // MARK: - 接続先

    private var connectionSection: some View {
        Section {
            // **Form の中の TextField は自動でラベル付きレイアウトになり、
            // 入力欄が右に寄る。** VStack で囲んでも Form の配置が優先されるので、
            // labelsHidden() でラベル扱いを外してから自前で並べる。
            VStack(alignment: .leading, spacing: 12) {
                labeledField("API の URL", example: "https://llm.example.co.jp/v1") {
                    TextField("", text: $urlInput)
                }
                labeledField("API キー", example: nil, hint: "不要なら空欄") {
                    SecureField("", text: $apiKeyInput)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button(isProbing ? "接続中…" : "接続してモデルを取得") { probe() }
                    .disabled(isProbing || urlInput.isEmpty)
                    .buttonStyle(.borderedProminent)
                if isProbing { ProgressView().controlSize(.small) }
            }

            if let probeMessage {
                Label(probeMessage,
                      systemImage: probeSucceeded ? "checkmark.circle.fill"
                                                  : "exclamationmark.triangle.fill")
                    .foregroundStyle(probeSucceeded ? .green : .orange)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !models.isEmpty {
                Picker("モデル", selection: Binding(
                    get: { model.settings.refinement.openaiCompatible.model },
                    set: { v in model.update { $0.refinement.openaiCompatible.model = v } })) {
                    ForEach(models) { m in Text(m.displayName).tag(m.id) }
                }
            } else if !model.settings.refinement.openaiCompatible.model.isEmpty {
                LabeledContent("モデル", value: model.settings.refinement.openaiCompatible.model)
            }
        } header: {
            // どの API に繋ぐのかを明示する。
            HStack(spacing: 6) {
                Text("接続先")
                Text("OpenAI 互換 API")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
        } footer: {
            Text("OpenAI Chat Completions 形式（`/v1/chat/completions`）に対応したサーバーに接続します。LM Studio、Ollama、vLLM、llama.cpp server、社内の互換ゲートウェイなど。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ラベルを上に置いて入力欄を左詰めにする。
    ///
    /// `labelsHidden()` が要点。これが無いと Form が入力欄をラベルの相方とみなし、
    /// 右端に寄せてしまう（プレースホルダもラベル位置に描かれる）。
    private func labeledField<Content: View>(
        _ label: String, example: String?, hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let example {
                Text("例: \(example)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - プロンプト

    private var promptSection: some View {
        Section {
            TextEditor(text: $promptInput)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
                .labelsHidden()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: promptInput) { _, new in
                    model.update { $0.refinement.prompt = new }
                }

            if promptInput.isEmpty {
                Text("空欄でも動きます。その場合は共通ルールだけが適用されます。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        } header: {
            Text("校正プロンプト")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("書き起こしたテキストと一緒に LLM へ渡す指示です。")
                Text("次のルールは常に適用されるので、ここに書く必要はありません。")
                    .foregroundStyle(.tertiary)
                Text("""
                    ・フィラー（「えー」「あのー」）を取り除く
                    ・句読点を補う
                    ・事実・固有名詞・数値を変えない
                    ・内容に答えず、整形だけする
                    ・前置きや説明を付けない
                    """)
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 接続

    private func probe() {
        guard let discover = model.dependencies.discoverModels else {
            probeMessage = "このビルドはネットワーク機能を含みません（オフライン版）"
            probeSucceeded = false
            return
        }
        isProbing = true
        probeMessage = nil
        let input = urlInput
        let key = apiKeyInput

        Task {
            // **キーはこれから叩くホストの口座へ保存する。**
            // 共通の口座に入れていた頃は、接続先を変えた瞬間に
            // 前のサーバー用のキーが新しいサーバーへ送られていた。
            if !key.isEmpty {
                model.storeAPIKey(key, forEndpoint: input)
                model.update { $0.refinement.openaiCompatible.requiresAPIKey = true }
            }
            model.allowProbe(for: input)

            switch await discover(input) {
            case .success(let baseURL, let found):
                models = found
                probeSucceeded = true
                probeMessage = "接続できました（モデル \(found.count) 件）"
                model.update { s in
                    // **探索で実際に通った URL を保存する。**
                    // 入力文字列から組み直すと、テストした URL と保存する URL が
                    // ずれて、接続テストだけ成功する状態になる。
                    s.refinement.openaiCompatible.baseURL = baseURL
                    if s.refinement.openaiCompatible.model.isEmpty, let first = found.first {
                        s.refinement.openaiCompatible.model = first.id
                    }
                }
                urlInput = baseURL   // 確定した URL を画面にも反映する
                apiKeyInput = ""     // 画面に残さない
            case .failure(let message):
                probeSucceeded = false
                probeMessage = message
            }
            isProbing = false
        }
    }
}
