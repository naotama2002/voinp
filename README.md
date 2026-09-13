# Voinp

macOS 26 専用の軽量な音声テキスト入力アプリ。
ホットキーを押して話すと、フォーカス中のアプリに書き起こしテキストが挿入される。

> **デフォルト起動状態では、音声データを外部に一切送信しない。**

macOS 26 の `SpeechAnalyzer` / `DictationTranscriber` を使うため、
音声認識は完全にオンデバイスで動く。whisper.cpp も Core ML モデルも同梱しない。

**現在の状態: 動作します。** 設計は [`docs/`](docs/) にある。

## できること

- ホットキー（ホールド / トグル / ハイブリッド）で録音 → 日本語の書き起こし → 最前面アプリに挿入
- 用語辞書による認識バイアス（製品名・人名・略語）
- セルフホスト LLM（OpenAI 互換 API）による校正。フィラー除去・誤変換修正。**既定はオフ**
- 校正プロンプトの表示・編集。`prompts/*.md` として保存される
- 設定 UI（ホットキー記録、言語、用語、挿入方法、校正、プライバシー）
- 初回セットアップのウィザード（権限とモデル取得を案内）

## 動作の様子

```
えーと、あのー、今日はですね、その、会議があってですね、まあ、ちょっと遅れそうです
                          ↓ 校正あり
今日は会議があって、ちょっと遅れそうです。
```

校正をオフにしても、`DictationTranscriber` が句読点を補うので実用になる。

## ドキュメント

| | |
|---|---|
| [00-overview.md](docs/00-overview.md) | 目的・非目標・スコープ・用語 |
| [01-architecture.md](docs/01-architecture.md) | ターゲット構成、パイプライン、セッション状態機械 |
| [02-transcription.md](docs/02-transcription.md) | 音声取り込みと音声認識 |
| [03-refinement.md](docs/03-refinement.md) | LLM 校正、モデル探索、失敗時の方針 |
| [04-prompts.md](docs/04-prompts.md) | プロンプト階層、インジェクション対策、出力ガード |
| [05-ui-input.md](docs/05-ui-input.md) | メニューバー、HUD、ホットキー、テキスト挿入 |
| [06-privacy.md](docs/06-privacy.md) | 脅威モデル、送信ゲート、監査、検証レシピ |
| [07-build.md](docs/07-build.md) | SPM 構成、`.app` 組み立て、署名と TCC、設定スキーマ、テスト |

## 使い方

```sh
make install     # ビルド → .app 組み立て → 自分の証明書で署名 → ~/Applications へ
make run         # 起動（LaunchServices 経由。TCC の許可が Voinp に付く）
make logs        # ログを追う
make test        # テスト
make verify      # 署名・依存・プライバシー保証の検証（docs/06-privacy.md）
```

初回起動時にセットアップウィザードが開き、マイクとアクセシビリティの許可、
日本語モデルの取得を案内する。

使うときは設定したホットキー（既定 `⌃⌥Space`）を押しながら話す。
離すと最前面のアプリにテキストが入力される。

### 校正を使う

設定 → 校正 で「LLM で校正する」を有効にし、OpenAI 互換 API の URL を入れて
「接続してモデルを取得」を押す。API キーは Keychain にのみ保存される。

校正は**既定でオフ**。オンにしても送るのは書き起こしたテキストだけで、
音声は送信しない。

## 動作要件

- **macOS 26.0 以降**。後方互換はない
- **Apple Silicon**。`SpeechTranscriber` のオンデバイスモデルが arm64 専用
- Xcode 26 以降 (ビルドに必要)
- codesigning 用の Apple Development 証明書

## 配布について

各自が clone して `make install` する。自分の証明書で署名するため、
リビルドしても TCC の権限が消えない ([07-build.md](docs/07-build.md))。

**Mac App Store では配布できない。**
他アプリへのテキスト挿入には Accessibility API と `CGEvent` セッションタップが必要で、
App Sandbox はどちらも拒否するため。これは恒久的な制約である。

## TypeWhisper との関係

[TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac) の fork ではなく別実装。
TypeWhisper (415 ファイル / 約 246,000 LOC) のソースを事前調査し、
**実際に踏まれた地雷の知見だけ**を設計に取り込んでいる。各 docs の「勘所」節を参照。

目標規模は約 3,000 LOC。

## ライセンス

未定。
