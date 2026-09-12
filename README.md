# Voinp

macOS 26 専用の軽量な音声テキスト入力アプリ。
ホットキーを押して話すと、フォーカス中のアプリに書き起こしテキストが挿入される。

> **デフォルト起動状態では、音声データを外部に一切送信しない。**

macOS 26 の `SpeechAnalyzer` / `DictationTranscriber` を使うため、
音声認識は完全にオンデバイスで動く。whisper.cpp も Core ML モデルも同梱しない。

**現在の状態: 仕様策定中。実装は未着手。**
設計は [`docs/`](docs/) にある。

## できること (予定)

- ホットキー (ホールド / トグル) で録音 → 日本語の書き起こし → 最前面アプリに挿入
- 社内用語辞書による認識バイアス (製品名・人名・略語)
- ローカル LLM (OpenAI 互換 API) による校正。フィラー除去・句読点整形。**既定はオフ**
- 校正プロンプトをプリセットとしてファイルで管理・共有

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

## 使い方 (実装後)

```sh
make install     # ビルド → .app 組み立て → 自分の証明書で署名 → ~/Applications へ
make run         # 起動 (ログがターミナルに出る)
make test        # テスト
make verify      # 署名・リンク・依存の検証 (docs/06-privacy.md)
```

初回起動時にマイクとアクセシビリティの権限を求める。
日本語の音声認識モデルは初回に OS 経由でダウンロードされる。

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
