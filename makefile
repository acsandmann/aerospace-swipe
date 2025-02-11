CC = clang
CFLAGS = -Wall -Wextra -O3
FRAMEWORKS = -framework CoreFoundation
LDLIBS = -ldl
TARGET = swipe

LAUNCH_AGENTS_DIR = $(HOME)/Library/LaunchAgents
PLIST_FILE = com.acsandmann.swipe.plist
PLIST_TEMPLATE = com.acsandmann.swipe.plist.in

ABS_TARGET_PATH = $(shell pwd)/$(TARGET)

.PHONY: all clean sign install_plist load_plist uninstall_plist install uninstall

all: $(TARGET)

$(TARGET): swipe.c
	$(CC) $(CFLAGS) -o $(TARGET) swipe.c $(FRAMEWORKS) $(LDLIBS)

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

uninstall_plist:
	@echo "Unloading launch agent..."
	launchctl unload $(LAUNCH_AGENTS_DIR)/$(PLIST_FILE)
	@echo "Removing launch agent plist from $(LAUNCH_AGENTS_DIR)..."
	rm -f $(LAUNCH_AGENTS_DIR)/$(PLIST_FILE)

build: all sign

install: all sign install_plist load_plist

uninstall: uninstall_plist clean

clean:
	rm -f $(TARGET)
