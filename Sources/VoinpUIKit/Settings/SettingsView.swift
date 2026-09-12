import SwiftUI
import VoinpCore
import VoinpEngine

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("一般", systemImage: "gearshape") }
            RecognitionSettings(model: model)
                .tabItem { Label("音声認識", systemImage: "waveform") }
            InsertionSettings(model: model)
                .tabItem { Label("テキスト挿入", systemImage: "text.cursor") }
            PrivacySettings(model: model)
                .tabItem { Label("プライバシー", systemImage: "lock") }
        }
        .frame(width: 520, height: 400)
    }
}

// MARK: - 一般

private struct GeneralSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("ホットキー") {
                KeyRecorderView(binding: Binding(
                    get: { model.settings.hotkey.binding },
                    set: { v in model.update { $0.hotkey.binding = v } }))

                Picker("押し方", selection: Binding(
                    get: { model.settings.hotkey.behavior },
                    set: { v in model.update { $0.hotkey.behavior = v } })) {
                    Text("長押し / 短押しどちらでも").tag("hybrid")
                    Text("押している間だけ").tag("hold")
                    Text("押して開始・押して終了").tag("toggle")
                }
                if model.settings.hotkey.behavior == "hybrid" {
                    Text("短く押すと録音が続き、もう一度押すと止まります。長押しの場合は離すと止まります。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Section("フィードバック") {
                Toggle("開始・終了時に音を鳴らす", isOn: Binding(
                    get: { model.settings.audio.playFeedbackSounds },
                    set: { v in model.update { $0.audio.playFeedbackSounds = v } }))
                Toggle("認識中のテキストを表示する", isOn: Binding(
                    get: { model.settings.ui.hudShowText },
                    set: { v in model.update { $0.ui.hudShowText = v } }))
                Text("画面共有中など、話した内容を見せたくない場合はオフにしてください。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 音声認識

private struct RecognitionSettings: View {
    let model: AppModel
    @State private var termsText: String = ""

    var body: some View {
        Form {
            Section("言語") {
                Picker("認識する言語", selection: Binding(
                    get: { model.settings.transcription.locale },
                    set: { v in model.update { $0.transcription.locale = v } })) {
                    ForEach(model.availableLocales, id: \.identifier) { loc in
                        Text(loc.displayName).tag(loc.identifier)
                    }
                }
                switch model.modelReadiness {
                case .ready:
                    Label("モデルは取得済みです", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.system(size: 11))
                case .needsModelDownload:
                    Label("この言語のモデルは未取得です", systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange).font(.system(size: 11))
                default:
                    EmptyView()
                }
                Text("この engine は話した言語を自動判定しません。話す言語を選んでください。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                Toggle("句読点を自動で補う", isOn: Binding(
                    get: { model.settings.transcription.punctuation == "automatic" },
                    set: { v in model.update { $0.transcription.punctuation = v ? "automatic" : "off" } }))
            }

            Section("用語ヒント") {
                Text("製品名・人名・社内用語を登録すると認識精度が上がります。1 行に 1 語。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: $termsText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 110)
                    .onChange(of: termsText) { _, new in
                        let terms = new.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        model.update { $0.transcription.termHints = Array(terms.prefix(100)) }
                    }
                Text("\(model.settings.transcription.termHints.count) 語（上限 100。多すぎるとかえって精度が落ちます）")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear { termsText = model.settings.transcription.termHints.joined(separator: "\n") }
    }
}

// MARK: - テキスト挿入

private struct InsertionSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("挿入方法") {
                Picker("方法", selection: Binding(
                    get: { model.settings.insertion.strategy },
                    set: { v in model.update { $0.insertion.strategy = v } })) {
                    Text("ペースト（⌘V を送る）").tag("paste")
                    Text("キー入力（1 文字ずつ）").tag("keystroke")
                }
                Text("ペーストはほぼすべてのアプリで動き、取り消しも 1 回で済みます。キー入力は遅い代わりにクリップボードを使いません。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if model.settings.insertion.strategy == "paste" {
                Section("クリップボード") {
                    Toggle("挿入後に元の内容へ戻す", isOn: Binding(
                        get: { model.settings.insertion.restoreClipboard },
                        set: { v in model.update { $0.insertion.restoreClipboard = v } }))
                    LabeledContent("戻すまでの待ち時間") {
                        Stepper("\(model.settings.insertion.pasteRestoreDelayMs) ms",
                                value: Binding(
                                    get: { model.settings.insertion.pasteRestoreDelayMs },
                                    set: { v in model.update { $0.insertion.pasteRestoreDelayMs = v } }),
                                in: 50...1000, step: 50)
                    }
                    Text("貼り付けが間に合わないアプリ（Electron 系など）では長めにしてください。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - プライバシー

private struct PrivacySettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("現在の状態") {
                Label(model.privacyHeadline, systemImage: model.settings.privacy.allowNetwork ? "globe" : "lock.fill")
                    .foregroundStyle(model.settings.privacy.allowNetwork ? .orange : .green)
            }

            Section("何がどこへ送られるか") {
                row("音声", "送信しません（この Mac 上でのみ処理）")
                row("書き起こし", model.settings.refinement.enabled ? "校正のため LLM へ" : "送信しません")
                row("整形後テキスト", "挿入先のアプリのみ")
            }

            Section("このアプリが行わないこと") {
                ForEach([
                    "利用統計・テレメトリの送信",
                    "クラッシュレポートの自動送信",
                    "起動時のアップデート確認",
                    "音声のディスクへの書き込み",
                    "書き起こしの保存（既定）",
                ], id: \.self) { t in
                    Label(t, systemImage: "xmark.circle").font(.system(size: 12))
                }
            }

            Section {
                Button("設定ファイルを開く") { model.openConfigDirectory() }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ kind: String, _ dest: String) -> some View {
        LabeledContent(kind) { Text(dest).font(.system(size: 12)).foregroundStyle(.secondary) }
    }
}

