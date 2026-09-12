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

.PHONY: build bundle sign verify install run run-unattached run-sim run-sim-slow launch logs logs-recent test clean reset-permissions help download-model

help:
	@echo "make test      テストを実行"
	@echo "make install   ビルド→署名→~/Applications へ配置"
	@echo "make run       install して起動（LaunchServices 経由。TCC の許可が Voinp に付く）"
	@echo "make logs      ログを追う"
	@echo "make run-sim   ダウンロード待ち UI を確認（進捗あり）"
	@echo "make run-sim-slow  同上（進捗を返さない実機同等の挙動）"
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

logs:
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level info --style compact

logs-recent:
	log show --predicate 'subsystem == "$(BUNDLE_ID)"' --last 10m --style compact

reset-permissions:
	tccutil reset Accessibility $(BUNDLE_ID) || true
	tccutil reset Microphone    $(BUNDLE_ID) || true

clean:
	rm -rf .build build
