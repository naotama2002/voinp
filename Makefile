APP           := Voinp
BUNDLE_ID     := com.naotama2002.voinp
VERSION       := 0.1.0
BUILD         := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
CONFIG        := debug
PRODUCT       := voinp
BIN           := $(shell swift build -c $(CONFIG) --show-bin-path)/$(PRODUCT)
APPDIR        := build/$(APP).app
INSTALLDIR    := $(HOME)/Applications/$(APP).app
ENTITLEMENTS  := Resources/voinp.entitlements

# ad-hoc 署名だと designated requirement が cdhash になり、リビルドのたびに
# TCC の許可が消える。必ず実 identity で署名する。
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning \
                   | awk '/Developer ID Application|Apple Development/ {print $$2; exit}')

.PHONY: build bundle sign verify install run run-unattached run-sim run-sim-slow use-en use-ja use-locale locales launch logs logs-recent test clean reset-permissions help download-model

help:
	@echo "make test      テストを実行"
	@echo "make install   ビルド→署名→~/Applications へ配置"
	@echo "make run       install して起動（LaunchServices 経由。TCC の許可が Voinp に付く）"
	@echo "make logs      ログを追う"
	@echo "make run-sim   ダウンロード待ち UI を確認（進捗あり）"
	@echo "make run-sim-slow  同上（進捗を返さない実機同等の挙動）"
	@echo "make use-en    認識を en-GB に切替（未取得なので本物の DL が走る）"
	@echo "make use-ja    ja-JP に戻す"
	@echo "make use-locale LOCALE=zh-TW  任意のロケールへ（未取得なら本物の DL）"
	@echo "make verify    署名・依存・プライバシー保証の検証"
	@echo "make download-model  日本語認識モデルを取得（初回のみ）"
	@echo "make reset-permissions  TCC の許可をリセット"

build:
	swift build -c $(CONFIG)

test:
	swift test

# 初回のみ。OS 経由でオンデバイス認識モデルを取得する。
download-model:
	swift build --product voinp-tools
	$(shell swift build --show-bin-path)/voinp-tools ja-JP

bundle: build
	rm -rf $(APPDIR)
	mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Resources
	cp $(BIN) $(APPDIR)/Contents/MacOS/voinp
	printf 'APPL????' > $(APPDIR)/Contents/PkgInfo
	sed -e 's/__VERSION__/$(VERSION)/g' -e 's/__BUILD__/$(BUILD)/g' \
	    -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' \
	    Resources/Info.plist > $(APPDIR)/Contents/Info.plist
	@[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns $(APPDIR)/Contents/Resources/ \
	  || echo "  (AppIcon.icns なし: スキップ)"
	cp -R Resources/Prompts $(APPDIR)/Contents/Resources/

sign: bundle
	@test -n "$(SIGN_IDENTITY)" || (echo "codesigning identity が見つかりません"; exit 1)
	codesign --force --sign $(SIGN_IDENTITY) \
	         --entitlements $(ENTITLEMENTS) \
	         --options runtime --generate-entitlement-der \
	         --timestamp=none \
	         $(APPDIR)

verify: sign
	@echo "== 署名 =="
	@codesign --verify --strict --verbose=2 $(APPDIR) 2>&1 | sed 's/^/  /'
	@echo "== designated requirement（TCC がこれで許可を記録する）=="
	@codesign -d -r- $(APPDIR) 2>&1 | sed 's/^/  /'
	@echo "== entitlements =="
	@codesign -d --entitlements - --xml $(APPDIR) 2>/dev/null | plutil -p - | sed 's/^/  /'
	@echo "== プライバシー =="
	@./scripts/verify-privacy.sh

install: sign
	@pkill -x voinp 2>/dev/null || true
	rm -rf $(INSTALLDIR)
	ditto $(APPDIR) $(INSTALLDIR)
	@echo "installed: $(INSTALLDIR)"

# LaunchServices 経由で起動する。
#
# **バイナリを直接起動してはいけない。** そうするとプロセスはシェルの子になり、
# TCC は「責任プロセス」をターミナルアプリ（Ghostty / Terminal.app など）と判定する。
# その状態でアクセシビリティを要求すると、許可されるのは Voinp ではなく
# ターミナルのほうになり、Voinp はいつまでも権限を得られない。
#
# stdout は見えなくなるので、ログは unified log から拾う（make logs）。
run: install
	open -n $(INSTALLDIR)
	@echo "起動しました。ログは 'make logs' で確認できます。"

# 直接起動。TCC の権限は効かないので、権限を要さない部分のデバッグ専用。
run-unattached: install
	@echo "警告: TCC の責任プロセスがターミナルになります。権限は Voinp に付きません。"
	$(INSTALLDIR)/Contents/MacOS/voinp

# ダウンロード待ち UI の確認。
# 本物の音声モデルは SIP 保護下で削除できないため「未取得の状態」を再現できない。
# TranscriptionProvider の接合部に差し替え実装を挿して、取得中の挙動だけを再現する。
#   run-sim       0→100% の進捗を返す
#   run-sim-slow  進捗を返さない（本物の Speech 資産と同じ挙動。不定表示になる）
run-sim: install
	@defaults delete $(BUNDLE_ID) onboardingCompleted 2>/dev/null || true
	open -n --env VOINP_SIMULATE_DOWNLOAD=1 $(INSTALLDIR)
	@echo "セットアップを開き「音声モデル」まで進んでください。"

run-sim-slow: install
	@defaults delete $(BUNDLE_ID) onboardingCompleted 2>/dev/null || true
	open -n --env VOINP_SIMULATE_DOWNLOAD=slow $(INSTALLDIR)
	@echo "セットアップを開き「音声モデル」まで進んでください（不定表示になります）。"

# 本物のモデルダウンロード UI を見るための切り替え。
# en-US は取得済みなので en-GB を使う（未取得かつ英語なので、取得後そのまま試せる）。
# 注意: 取得したモデルは SIP 保護下にあり削除できない。
# 注意: CONFIG はビルド構成 (debug/release) で既に使っている。別名にすること。
VOINP_CONFIG_DIR  := $(HOME)/Library/Application Support/voinp
VOINP_CONFIG_FILE := $(VOINP_CONFIG_DIR)/config.json

# 任意のロケールに切り替える。未取得のものを指定すれば本物の DL が走る。
#   make use-locale LOCALE=zh-TW
# 注意: 取得したモデルは削除できず、同時に扱えるのは 5 ロケールまで。
use-locale:
	@test -n "$(LOCALE)" || (echo "使い方: make use-locale LOCALE=zh-TW"; exit 1)
	@mkdir -p "$(VOINP_CONFIG_DIR)"
	@printf '{\n  "schemaVersion": 1,\n  "transcription": { "locale": "$(LOCALE)" }\n}\n' > "$(VOINP_CONFIG_FILE)"
	@echo "認識ロケールを $(LOCALE) にしました。戻すには make use-ja"

# 未取得のロケールを一覧する（取得はしない）
locales:
	@swift build --product voinp-tools >/dev/null 2>&1
	@echo "現在の設定: $$(grep -o '"locale"[^,}]*' "$(VOINP_CONFIG_FILE)" 2>/dev/null || echo '(既定 ja-JP)')"

use-en:
	@mkdir -p "$(VOINP_CONFIG_DIR)"
	@printf '{\n  "schemaVersion": 1,\n  "transcription": { "locale": "en-GB" }\n}\n' > "$(VOINP_CONFIG_FILE)"
	@echo "認識ロケールを en-GB にしました（未取得なのでウィザードでダウンロードが走ります）"
	@echo "戻すには: make use-ja"

use-ja:
	@mkdir -p "$(VOINP_CONFIG_DIR)"
	@printf '{\n  "schemaVersion": 1,\n  "transcription": { "locale": "ja-JP" }\n}\n' > "$(VOINP_CONFIG_FILE)"
	@echo "認識ロケールを ja-JP に戻しました"

logs:
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level info --style compact

logs-recent:
	log show --predicate 'subsystem == "$(BUNDLE_ID)"' --last 10m --style compact

reset-permissions:
	tccutil reset Accessibility $(BUNDLE_ID) || true
	tccutil reset Microphone    $(BUNDLE_ID) || true

clean:
	rm -rf .build build
