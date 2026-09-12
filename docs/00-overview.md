# 00. 概要

## これは何か

**Voinp** は macOS 26 専用の軽量な音声テキスト入力アプリ。
ホットキーを押して話すと、フォーカス中のアプリに書き起こしテキストが挿入される。

> **旗印: デフォルト起動状態では、音声データを外部に一切送信しない。**

macOS 26 (Tahoe) が `Speech.framework` に追加した `SpeechAnalyzer` / `SpeechTranscriber` /
`DictationTranscriber` は完全オンデバイスで動作し、日本語 (ja-JP) にも対応する。
これにより whisper.cpp や Core ML モデルを同梱する必要がなくなり、
アプリ本体は数 MB、コードは 3,000 行程度に収まる。

## 目的

- 日本語で快適に音声入力できること。認識から挿入までが速く、入力が止まらないこと
- 「音声がこの Mac から出ていない」ことを、口約束ではなく**検証可能な形**で示せること
- 社内ツールとして、用語辞書と校正プロンプトをチームで共有・改善できること
- 実装が小さく、1 人が全体を把握したまま保守できること

## 非目標

以下は意図的に作らない。

| 作らないもの | 理由 |
|---|---|
| プラグインシステム | 動的ロードは `disable-library-validation` を要求し、攻撃面と複雑さが釣り合わない |
| ライセンス管理・課金 | 社内ツール |
| iCloud / デバイス間同期 | 「外に出さない」と真っ向から矛盾する |
| HTTP API サーバ / CLI | 別プロセスからの遠隔操作は監査面倒 |
| Workflow / Profile (アプリ別・サイト別ルール) | プリセット + ホットキーで十分 |
| Widget / Finder サービス / ファイル書き起こし | リアルタイム入力に集中する |
| 多言語 UI ローカライズ | 日本語と英語のみ。文字列カタログは使わない |
| 自動アップデート (Sparkle 等) | ネットワーク経路と署名鍵の負債が増える |
| Mac App Store 配布 | サンドボックスではテキスト挿入が不可能。[07](07-build.md) 参照 |

## TypeWhisper との関係

このプロジェクトは [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac) の fork **ではない**。
別実装である。ただし TypeWhisper のソースを事前調査し、
**実際に踏まれた地雷の知見だけ**を設計に取り込んでいる (各 docs の「勘所」節)。

| | TypeWhisper | Voinp |
|---|---|---|
| 規模 | 415 ファイル / 約 246,000 LOC | 目標 約 3,000 LOC |
| 最低 OS | macOS 14 | **macOS 26 のみ** |
| ビルド | Xcode プロジェクト (pbxproj 9,184 行) | **SPM のみ** |
| STT | プラグイン方式 (WhisperKit / Parakeet / MLX / クラウド 20 種) | **Apple オンデバイス 1 本**、差し替え可能な口だけ用意 |
| LLM | プラグイン方式 | OpenAI 互換 1 本 + 将来の追加口 |
| 設定 | UserDefaults 138 キー + SwiftData 8 モデル + Keychain | **config.json + prompts/\*.md + Keychain** |
| 配布 | Developer ID + notarize + DMG + Sparkle | **各自 `make install`** |

upstream 追従をやめ、必要な機能だけを自分たちの速度で足せる状態にすることが、
別実装を選んだ理由である。

## スコープ: step 1 / step 2

### step 1 (いま作るもの)

- 音声 → テキスト: **macOS 内蔵 API** (`SpeechAnalyzer`)。完全オンデバイス
- テキスト校正: **OpenAI 互換 API のローカル LLM** (LM Studio / Ollama / llama.cpp / vLLM)
  - ベース URL を入力するとモデル一覧を取得してピッカーに出す
  - 校正は**既定でオフ**。オンにしても送るのは *テキスト* であり *音声* ではない
- テキスト挿入、ホットキー (ホールド / トグル)、HUD、設定画面

### step 2 (あとで足すもの)

- 音声 → テキスト を外部 API に差し替え可能にする (OpenAI Whisper / Deepgram など)
- 校正 LLM に OpenAI / Anthropic / Gemini を追加

step 1 のプロトコル設計は step 2 を**想定して**作るが、step 2 のコードは書かない。
step 2 で初めて「音声が Mac の外に出る」ため、そのときにプロセス分離を検討する ([06](06-privacy.md))。

## データの 3 系統

このアプリを理解する上で最も重要な区別。
「外に出る / 出ない」は **1 つのフラグではなく 3 つ**あり、docs 全体でこの粒度を維持する。

| 系統 | step 1 での送信先 | step 2 で変わりうるか |
|---|---|---|
| **音声** (PCM) | **どこにも出ない**。プロセス内で破棄 | クラウド STT を選ぶと出る |
| **書き起こしテキスト** | 校正オン時のみ LLM へ (既定は `127.0.0.1`) | クラウド LLM を選ぶと出る |
| **整形後テキスト** | 挿入先アプリのみ | 変わらない |

`127.0.0.1` のローカル LLM に書き起こしを送っても、
**「音声がこの Mac から出ない」は厳密に成立する**。この誠実さを UI にもそのまま出す。

## 用語

| 用語 | 意味 |
|---|---|
| セッション | ホットキー押下から挿入完了までの 1 回のディクテーション |
| volatile / 暫定結果 | 確定前の認識結果。次の結果で**丸ごと置き換わる**。追記してはいけない |
| final / 確定結果 | 確定した認識結果。追記していく |
| 校正 (refinement) | 書き起こしを LLM に通してフィラー除去・句読点整形などを行うこと |
| 生原稿 (raw transcript) | 校正前の、STT が出したままのテキスト |
| プリセット | 校正の指示セット。`prompts/*.md` として定義する |
| egress | このアプリからの外向き通信 |
| PrivacyPosture | 現在の設定から導出される「何がどこへ出るか」の状態 |

## ドキュメント一覧

| ファイル | 内容 |
|---|---|
| [00-overview.md](00-overview.md) | この文書 |
| [01-architecture.md](01-architecture.md) | ターゲット構成、パイプライン、セッション状態機械、isolation |
| [02-transcription.md](02-transcription.md) | 音声取り込みと音声認識、プロバイダ抽象 |
| [03-refinement.md](03-refinement.md) | LLM 校正、モデル探索、失敗時の方針 |
| [04-prompts.md](04-prompts.md) | プロンプト階層、インジェクション対策、出力ガード |
| [05-ui-input.md](05-ui-input.md) | メニューバー、HUD、ホットキー、テキスト挿入 |
| [06-privacy.md](06-privacy.md) | 脅威モデル、送信ゲート、監査、検証レシピ |
| [07-build.md](07-build.md) | SPM 構成、`.app` 組み立て、署名と TCC、設定スキーマ、テスト |

## 未決事項

- `DictationTranscriber` と `SpeechTranscriber` の日本語精度比較 ([02](02-transcription.md))
- ペーストボードの `ConcealedType` が Universal Clipboard を抑止するか ([05](05-ui-input.md))
- 社内配布に移行する場合の Developer ID 取得と notarize ([07](07-build.md))
- 社内用語辞書の配布方法 ([02](02-transcription.md))
- Apple Intelligence を有効にした環境での `FoundationModels` の日本語品質 ([03](03-refinement.md))
