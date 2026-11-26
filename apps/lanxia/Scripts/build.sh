#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
BUILD_DIR="${STASHCAT_BUILD_DIR:-/tmp/StashCat-build}"
APP_PATH="$BUILD_DIR/Wings.app"
TASK_SDK_PATH="${STASHCAT_SDK_PATH:-$(xcrun --show-sdk-path)}"
# This Mac's CLT SDK 27 exposes SwiftUI.State macros but lacks SwiftUIMacros.
# The installed 26.5 SDK supports the macOS 14 baseline and guarded macOS 26 glass APIs; keep this choice
# local to the build instead of changing the user's global developer directory.
if [[ -z "${STASHCAT_SDK_PATH:-}" && "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    TASK_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
mkdir -p "$BUILD_DIR"
if [[ -e "$APP_PATH" ]]; then rm -rf -- "$APP_PATH"; fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
xcrun swiftc -O -parse-as-library -sdk "$TASK_SDK_PATH" -target arm64-apple-macos14.0 "$PROJECT_DIR"/Sources/*.swift -framework AppKit -framework SwiftUI -framework QuartzCore -framework ServiceManagement -framework UserNotifications -framework PDFKit -framework Vision -framework ImageIO -framework Speech -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework CoreImage -framework Carbon -framework Security -o "$APP_PATH/Contents/MacOS/StashCat"
cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/StashCatGlass.icns" "$APP_PATH/Contents/Resources/StashCatGlass.icns"
"$SCRIPT_DIR/build-harness.sh" "$APP_PATH/Contents/Resources/Harness"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
print -r -- "$APP_PATH"
