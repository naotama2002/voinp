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
            // 入力欄は左詰め。LabeledContent だと右端に寄って読みにくい。
            field("API の URL", placeholder: "https://llm.example.co.jp/v1") {
                TextField("", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
            }

            field("API キー", placeholder: nil) {
                SecureField("不要なら空欄", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
            }

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
    private func field<Content: View>(_ label: String, placeholder: String?,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let placeholder {
                Text("例: \(placeholder)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - プロンプト

    private var promptSection: some View {
        Section {
            TextEditor(text: $promptInput)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 140)
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
            if !key.isEmpty {
                model.storeAPIKey(key)
                model.update { $0.refinement.openaiCompatible.requiresAPIKey = true }
            }
            model.allowProbe(for: input)

            switch await discover(input) {
            case .success(let found):
                models = found
                probeSucceeded = true
                probeMessage = "接続できました（モデル \(found.count) 件）"
                model.update { s in
                    s.refinement.openaiCompatible.baseURL = normalizedURL(input)
                    if s.refinement.openaiCompatible.model.isEmpty, let first = found.first {
                        s.refinement.openaiCompatible.model = first.id
                    }
                }
                apiKeyInput = ""   // 画面に残さない
            case .failure(let message):
                probeSucceeded = false
                probeMessage = message
            }
            isProbing = false
        }
    }

    private func normalizedURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return s.hasSuffix("/v1") ? s : s + "/v1"
    }
}
