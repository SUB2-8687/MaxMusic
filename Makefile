ifeq ($(ROOTLESS),1)
THEOS_PACKAGE_SCHEME = rootless
else ifeq ($(ROOTHIDE),1)
THEOS_PACKAGE_SCHEME = roothide
endif

ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTubeMusic
TARGET = iphone:clang:16.5:13.0
PACKAGE_VERSION = 2.4.1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTMusicUltimate
$(TWEAK_NAME)_FILES = $(filter-out Source/Sideloading.x, $(wildcard Source/*.x))
$(TWEAK_NAME)_FILES += $(shell find Source -name '*.m' -not -path 'Source/WireGuard/*')
ADDITIONAL_CFLAGS = -Wno-error -Wno-incomplete-umbrella -Wno-module-import-in-implementation -w
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-incomplete-umbrella -Wno-error -w -DTWEAK_VERSION=$(PACKAGE_VERSION)
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation AVFoundation AudioToolbox VideoToolbox MediaPlayer
$(TWEAK_NAME)_OBJ_FILES = $(shell find Source/Utils/lib -name '*.a')
$(TWEAK_NAME)_LIBRARIES = bz2 c++ iconv z
ifeq ($(SIDELOADING),1)
$(TWEAK_NAME)_FILES += Source/Sideloading.x
endif

# App-local WireGuard (wireguard-go + gVisor netstack, no system VPN).
# Build the engine first: WireGuard/build-ios.sh  ->  WireGuard/build/libytmuwg.a
ifeq ($(WIREGUARD),1)
YTMUWG_ARCHIVE = WireGuard/build/libytmuwg.a
ifeq ($(wildcard $(YTMUWG_ARCHIVE)),)
$(error $(YTMUWG_ARCHIVE) is missing; run WireGuard/build-ios.sh first)
endif
$(TWEAK_NAME)_FILES += $(wildcard Source/WireGuard/*.m)
$(TWEAK_NAME)_OBJ_FILES += $(YTMUWG_ARCHIVE)
$(TWEAK_NAME)_FRAMEWORKS += Network Security CoreFoundation
$(TWEAK_NAME)_LIBRARIES += resolv

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/Application Support/YTMusicUltimate.bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp WireGuard/THIRD_PARTY_LICENSES.txt "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/Application Support/YTMusicUltimate.bundle/WireGuard-THIRD_PARTY_LICENSES.txt"$(ECHO_END)
endif

include $(THEOS_MAKE_PATH)/tweak.mk
