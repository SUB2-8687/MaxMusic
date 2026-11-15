#!/usr/bin/env bash
# Build on macOS with Xcode; use --groups-only when the main tweak already
# contains Source/NowPlaying/YTMUNowPlayingFix.m.
set -euo pipefail
cd "$(dirname "$0")/.."
output=${1:?Usage: build-repair.sh OUTPUT [--groups-only]}
sources=(Source/WidgetBridge/YTMUAppGroups.m)
if [[ ${2:-} != --groups-only ]]; then sources+=(Source/NowPlaying/YTMUNowPlayingFix.m); fi
xcrun --sdk iphoneos clang -target arm64-apple-ios13.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -dynamiclib -fobjc-arc -fblocks -Os -framework Foundation -framework UIKit -framework MediaPlayer \
  -install_name @rpath/YTMUPlaybackRepair.dylib "${sources[@]}" -o "$output"
ldid -S "$output"
