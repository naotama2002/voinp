import SwiftUI
import VoinpCore

struct RefinementSettings: View {
    let model: AppModel
    @State private var urlInput = ""
    @State private var apiKeyInput = ""
    @State private var isProbing = false
    @State private var probeMessage: String?
    @State private var probeSucceeded = false
    @State private var models: [ModelInfo] = []
    @State private var editingPrompt = false

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
                presetSection
            }
        }
        .formStyle(.grouped)
        .onAppear { urlInput = model.settings.refinement.openaiCompatible.baseURL }
        .sheet(isPresented: $editingPrompt) {
            PromptEditorView(model: model, presetID: model.settings.refinement.defaultPresetID)
        }
    }

    // MARK: - 接続先

    private var connectionSection: some View {
        Section("接続先") {
            // LabeledContent だと入力欄が右詰めになって読みにくい。
            // ラベルを上に置いて左詰めにする。
            VStack(alignment: .leading, spacing: 4) {
                Text("API の URL").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("https://llm.example.co.jp", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API キー（不要なら空欄）").font(.system(size: 11)).foregroundStyle(.secondary)
                SecureField("", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        }
    }

    // MARK: - プリセット

    private var presetSection: some View {
        Section("整形の種類") {
            Picker("プリセット", selection: Binding(
                get: { model.settings.refinement.defaultPresetID },
                set: { v in model.update { $0.refinement.defaultPresetID = v } })) {
                ForEach(model.presets, id: \.id) { p in
                    Text(model.isPresetCustomized(p.id) ? p.name + "（編集済み）" : p.name)
                        .tag(p.id)
                }
            }

            // **何をするプリセットなのかを実際のプロンプトで示す。**
            // 一行の説明だけだと、選んだ結果どうなるか分からない。
            let current = model.preset(id: model.settings.refinement.defaultPresetID)
            if current.skipsLLM {
                Text("LLM を呼びません。認識結果をそのまま挿入します。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("このプリセットが LLM に渡す指示")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(current.body.isEmpty
                             ? "（追加の指示なし。フィラー除去と句読点整形の共通ルールだけが適用されます）"
                             : current.body)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 90)
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

                    HStack(spacing: 10) {
                        Button("編集…") { editingPrompt = true }
                        if model.isPresetCustomized(current.id) {
                            Button("組み込みに戻す") { model.resetPrompt(id: current.id) }
                        }
                        Spacer()
                        Button("プロンプトのフォルダを開く") { model.openPromptsDirectory() }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                }
            }
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

// MARK: - プロンプト編集

struct PromptEditorView: View {
    let model: AppModel
    let presetID: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var body_ = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プロンプトの編集").font(.headline)
            Text("ここに書いた内容が、共通ルールに続けて LLM へ渡されます。")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            TextField("名前", text: $name).textFieldStyle(.roundedBorder)

            TextEditor(text: $body_)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            Text("共通ルール（フィラー除去・事実を変えない・前置きを付けない など）は常に適用されます。ここには追加の指示だけを書いてください。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("保存") {
                    model.savePrompt(id: presetID, name: name, body: body_)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .onAppear {
            let p = model.preset(id: presetID)
            name = p.name
            body_ = p.body
        }
    }
}
