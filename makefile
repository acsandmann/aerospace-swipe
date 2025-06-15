CC = clang
CFLAGS = -std=c99 -O3 -march=native -flto -fomit-frame-pointer -funroll-loops -g -Wall -Wextra -Wno-pointer-integer-compare -Wno-incompatible-pointer-types-discards-qualifiers -Wno-absolute-value
FRAMEWORKS = -framework CoreFoundation -framework IOKit -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Cocoa
LDLIBS = -ldl
TARGET = swipe

LAUNCH_AGENTS_DIR = $(HOME)/Library/LaunchAgents
PLIST_FILE = com.acsandmann.swipe.plist
PLIST_TEMPLATE = com.acsandmann.swipe.plist.in

SRC_FILES = src/aerospace.c src/cJSON.c src/haptic.c src/event_tap.m src/main.m

BINARY = swipe
BINARY_NAME = AerospaceSwipe
APP_BUNDLE = $(BINARY_NAME).app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
INFO_PLIST = $(APP_CONTENTS)/Info.plist

ABS_TARGET_PATH = $(shell pwd)/$(APP_MACOS)/$(BINARY_NAME)

.PHONY: all clean sign install_plist load_plist uninstall_plist install uninstall

ifeq ($(shell uname -sm),Darwin arm64)
	ARCH= -arch arm64
else
	ARCH= -arch x86_64
endif

bundle: $(BINARY)
	@echo "Creating app bundle $(APP_BUNDLE)..."
	mkdir -p $(APP_MACOS)
	mkdir -p $(APP_CONTENTS)/Resources
	cp $(BINARY) $(APP_MACOS)/$(BINARY_NAME)
	@echo "Generating Info.plist..."
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(INFO_PLIST)
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(INFO_PLIST)
	@echo '<plist version="1.0">' >> $(INFO_PLIST)
	@echo '<dict>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleExecutable</key>' >> $(INFO_PLIST)
	@echo '    <string>$(BINARY_NAME)</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleIdentifier</key>' >> $(INFO_PLIST)
	@echo '    <string>com.example.swipe</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleName</key>' >> $(INFO_PLIST)
	@echo '    <string>$(BINARY_NAME)</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundlePackageType</key>' >> $(INFO_PLIST)
	@echo '    <string>APPL</string>' >> $(INFO_PLIST)
	@echo '    <key>NSPrincipalClass</key>' >> $(INFO_PLIST)
	@echo '    <string>NSApplication</string>' >> $(INFO_PLIST)
	@echo '    <key>LSUIElement</key>' >> $(INFO_PLIST)
	@echo '    <true/>' >> $(INFO_PLIST)
	@echo '</dict>' >> $(INFO_PLIST)
	@echo '</plist>' >> $(INFO_PLIST)
	@echo "APPL????" > $(APP_CONTENTS)/PkgInfo
	codesign --entitlements accessibility.entitlements --sign - $(APP_BUNDLE)

all: $(TARGET)

$(TARGET): $(SRC_FILES)
	$(CC) $(CFLAGS) $(ARCH) -o $(TARGET) $(SRC_FILES) $(FRAMEWORKS) $(LDLIBS)

sign: $(TARGET)
	@echo "Signing $(TARGET) with accessibility entitlement..."
	codesign --entitlements accessibility.entitlements --sign - $(TARGET)

install_plist:
	@echo "Generating launch agent plist with binary path $(ABS_TARGET_PATH)..."
	mkdir -p $(LAUNCH_AGENTS_DIR)
	sed "s|@TARGET_PATH@|$(ABS_TARGET_PATH)|g" $(PLIST_TEMPLATE) > $(LAUNCH_AGENTS_DIR)/$(PLIST_FILE)
	@echo "Launch agent plist installed to $(LAUNCH_AGENTS_DIR)/$(PLIST_FILE)"

load_plist:
	@echo "Loading launch agent..."
	launchctl load $(LAUNCH_AGENTS_DIR)/$(PLIST_FILE)

unload_plist:
	@echo "Unloading launch agent..."
	launchctl unload $(LAUNCH_AGENTS_DIR)/$(PLIST_FILE)

uninstall_plist:
	@echo "Removing launch agent plist from $(LAUNCH_AGENTS_DIR)..."
	rm -f $(LAUNCH_AGENTS_DIR)/$(PLIST_FILE)

build: all sign

install: all bundle install_plist load_plist

uninstall: unload_plist uninstall_plist clean

restart: unload_plist load_plist

format:
	clang-format -i -- **/**.c **/**.h **/**.m

clean:
	rm -rf $(TARGET) $(APP_BUNDLE)
