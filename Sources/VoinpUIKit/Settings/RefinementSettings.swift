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
                Section("接続先") {
                    TextField("https://例: llm.example.co.jp", text: $urlInput)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API キー（不要なら空欄）", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)

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
                    }
                }

                Section("この接続先は") {
                    Picker("", selection: Binding(
                        get: { model.settings.refinement.openaiCompatible.operatorKind },
                        set: { v in model.update { $0.refinement.openaiCompatible.operatorKind = v } })) {
                        Text("自社・自分で運用している").tag("self-hosted")
                        Text("外部サービス").tag("vendor")
                    }
                    .pickerStyle(.radioGroup)
                    Text("表示にのみ使う申告です。送信の許可はネットワーク設定（到達範囲）だけで決まります。")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }

                Section("整形の種類") {
                    Picker("プリセット", selection: Binding(
                        get: { model.settings.refinement.defaultPresetID },
                        set: { v in model.update { $0.refinement.defaultPresetID = v } })) {
                        ForEach(Preset.builtins) { p in Text(p.name).tag(p.id) }
                    }
                    Text(presetDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            urlInput = model.settings.refinement.openaiCompatible.baseURL
        }
    }

    private var presetDescription: String {
        switch model.settings.refinement.defaultPresetID {
        case "raw": "LLM を呼びません。認識結果をそのまま挿入します。"
        case "polite": "です・ます調に統一します。"
        case "slack": "チャット向けに簡潔にします。箇条書きも許容します。"
        case "translate-en": "英語に翻訳します。"
        default: "フィラーを取り除き、句読点を整えます。内容は変えません。"
        }
    }

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
            // キーは Keychain にだけ入れる。設定ファイルには書かない。
            if !key.isEmpty {
                model.storeAPIKey(key)
                model.update { $0.refinement.openaiCompatible.requiresAPIKey = true }
            }
            // 未保存のホストへ探索するため、短命の許可を発行する。
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

    /// 表示用。実際の正規化は探索側で行われる。
    private func normalizedURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return s.hasSuffix("/v1") ? s : s + "/v1"
    }
}
