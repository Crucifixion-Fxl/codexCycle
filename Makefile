PROJECT := codexCycle.xcodeproj
SCHEME := codexCycle
DERIVED_DATA := /private/tmp/fxl-codexCycle-DerivedData
DESTINATION := platform=macOS,arch=arm64
APP_BUNDLE := $(DERIVED_DATA)/Build/Products/Release/codexCycle.app
DEBUG_APP_BUNDLE := $(DERIVED_DATA)/Build/Products/Debug/codexCycle.app
INSTALL_PATH := /Applications/codexCycle.app

.PHONY: build test release dmg install uninstall purge clean

build:
	xcodebuild -quiet \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO \
		build
	@/usr/bin/xattr -cr "$(DEBUG_APP_BUNDLE)"
	@/usr/bin/codesign --force --deep --sign - "$(DEBUG_APP_BUNDLE)"

test:
	xcodebuild -quiet \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO \
		test

release:
	xcodebuild -quiet \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Release \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO \
		build
	@/usr/bin/xattr -cr "$(APP_BUNDLE)"
	@/usr/bin/codesign --force --deep --sign - "$(APP_BUNDLE)"

dmg: release
	@./scripts/create-dmg.sh "$(APP_BUNDLE)" "dist"

install: release
	@/usr/bin/pkill -x codexCycle >/dev/null 2>&1 || true
	@/bin/rm -rf "$(INSTALL_PATH)"
	@/usr/bin/ditto "$(APP_BUNDLE)" "$(INSTALL_PATH)"
	@/usr/bin/open "$(INSTALL_PATH)"
	@echo "已安装并启动 $(INSTALL_PATH)"

uninstall:
	@if [ -x "$(INSTALL_PATH)/Contents/MacOS/codexCycle" ]; then \
		"$(INSTALL_PATH)/Contents/MacOS/codexCycle" --unregister-login-item || true; \
	fi
	@/usr/bin/pkill -x codexCycle >/dev/null 2>&1 || true
	@/bin/rm -rf "$(INSTALL_PATH)"
	@echo "已卸载 codexCycle；偏好设置已保留"

purge: uninstall
	@/usr/bin/defaults delete com.fxl.codexCycle >/dev/null 2>&1 || true
	@echo "已删除 com.fxl.codexCycle 偏好设置"

clean:
	@/bin/rm -rf "$(DERIVED_DATA)"
