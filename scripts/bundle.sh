#!/bin/bash
set -e

if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# Validate the SDK/toolchain pair before a full build. Some Command Line Tools
# installations include a newer SwiftUI SDK without its required macro plugin.
SDK_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-sdk.XXXXXX")"
trap 'rm -rf "$SDK_CHECK_DIR"' EXIT
cat > "$SDK_CHECK_DIR/check.swift" <<'SWIFT'
import SwiftUI
struct SDKCheck: View {
    @State private var enabled = false
    var body: some View { Toggle("Check", isOn: $enabled) }
}
SWIFT

sdk_supports_swiftui() {
    swiftc -typecheck -sdk "$1" "$SDK_CHECK_DIR/check.swift" > "$SDK_CHECK_DIR/error.log" 2>&1
}

if [ -n "${SDKROOT:-}" ]; then
    if ! sdk_supports_swiftui "$SDKROOT"; then
        echo "The requested SDK cannot compile SwiftUI with this toolchain: $SDKROOT" >&2
        cat "$SDK_CHECK_DIR/error.log" >&2
        exit 1
    fi
else
    SELECTED_SDK="$(xcrun --sdk macosx --show-sdk-path)"
    if sdk_supports_swiftui "$SELECTED_SDK"; then
        SDKROOT="$SELECTED_SDK"
    else
        echo "The selected SDK cannot compile SwiftUI; checking other installed SDKs." >&2
        for candidate in "$(dirname "$SELECTED_SDK")"/MacOSX*.sdk; do
            # Skip aliases so the same installed SDK is not checked repeatedly.
            [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
            [ "$candidate" -ef "$SELECTED_SDK" ] && continue
            if sdk_supports_swiftui "$candidate"; then
                SDKROOT="$candidate"
                break
            fi
        done
        if [ -z "${SDKROOT:-}" ]; then
            echo "No usable macOS SDK found. Repair Command Line Tools or select a complete Xcode installation." >&2
            cat "$SDK_CHECK_DIR/error.log" >&2
            exit 1
        fi
    fi
fi
export SDKROOT
echo "Using SDK: $SDKROOT"

APP_BUNDLE_NAME="AgentDock"
EXECUTABLE_NAME="AgentDock"

SWIFT_BUILD_FLAGS=("-c" "release" "--arch" "arm64" "--sdk" "$SDKROOT")
swift build "${SWIFT_BUILD_FLAGS[@]}"

BUILD_DIR="$(swift build "${SWIFT_BUILD_FLAGS[@]}" --show-bin-path)"
OUTPUT_DIR="build"
APP_BUNDLE="$OUTPUT_DIR/$APP_BUNDLE_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "📦 Assembling $APP_BUNDLE_NAME.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

cp "$BUILD_DIR/$EXECUTABLE_NAME" "$MACOS/$EXECUTABLE_NAME"
chmod +x "$MACOS/$EXECUTABLE_NAME"

cp -R "Resources/CursorHooks" "$RESOURCES/CursorHooks"
cp -R "Resources/AntigravityHooks" "$RESOURCES/AntigravityHooks"
cp -R "Resources/ClaudeHooks" "$RESOURCES/ClaudeHooks"
cp -R "Resources/CodexHooks" "$RESOURCES/CodexHooks"
cp -R "Resources/OpenCodeHooks" "$RESOURCES/OpenCodeHooks"

mkdir -p "$RESOURCES/ProviderIcons"
cp Resources/ProviderIcons/*.png "$RESOURCES/ProviderIcons/"

mkdir -p "$RESOURCES/Icons"
cp Resources/Icons/*.pdf "$RESOURCES/Icons/"
if [ -f Resources/Icons/productiveApps.svg ]; then
    cp Resources/Icons/productiveApps.svg "$RESOURCES/Icons/"
fi

if [ -d "Resources/Fonts" ]; then
    cp -R "Resources/Fonts" "$RESOURCES/Fonts"
fi

if [ -d "Resources/Sounds" ]; then
    cp -R "Resources/Sounds" "$RESOURCES/Sounds"
fi

if [ -f "Resources/wallpaper.png" ]; then
    cp "Resources/wallpaper.png" "$RESOURCES/wallpaper.png"
fi

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

cp Resources/AppLogo*.png "$RESOURCES/" 2>/dev/null || true
cp Resources/MenuBarIcon*.png "$RESOURCES/" 2>/dev/null || true
cp Resources/MenuBarTemplate*.png "$RESOURCES/" 2>/dev/null || true

cp "Resources/Info.plist" "$CONTENTS/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$RESOURCES/"
echo -n "APPL????" > "$CONTENTS/PkgInfo"

if command -v codesign &> /dev/null; then
    echo "🔏 Signing app bundle..."
    SIGNING_FLAGS=(--force --sign "${SIGNING_IDENTITY:--}")
    if [ "${SIGNING_IDENTITY:--}" != "-" ]; then
        SIGNING_FLAGS+=(--options runtime --timestamp)
    fi
    codesign "${SIGNING_FLAGS[@]}" "$APP_BUNDLE"
    codesign --verify --deep --strict "$APP_BUNDLE"
fi

echo "✅ Successfully built $APP_BUNDLE!"
echo "👉 Run with: open \"$PWD/$APP_BUNDLE\""
