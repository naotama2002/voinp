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

.PHONY: build bundle sign verify install run launch test clean reset-permissions help

help:
	@echo "make test      テストを実行"
	@echo "make install   ビルド→署名→~/Applications へ配置"
	@echo "make run       install して起動（ログが端末に出る）"
	@echo "make verify    署名・依存・プライバシー保証の検証"
	@echo "make reset-permissions  TCC の許可をリセット"

build:
	swift build -c $(CONFIG)

test:
	swift test

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

# バイナリを直接起動するので stdout/stderr が端末に出る。
# TCC は実行ファイルのパスから .app を辿るため、権限は通常どおり効く。
run: install
	$(INSTALLDIR)/Contents/MacOS/voinp

launch: install
	open -n $(INSTALLDIR)

reset-permissions:
	tccutil reset Accessibility $(BUNDLE_ID) || true
	tccutil reset Microphone    $(BUNDLE_ID) || true

clean:
	rm -rf .build build
