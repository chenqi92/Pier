#!/bin/bash
# ============================================================
# Pier — DMG Packaging Script
# ============================================================
# Creates a distributable DMG with custom layout.
#
# Prerequisites:
#   brew install create-dmg
#
# Usage:
#   ./scripts/package_dmg.sh [path/to/Pier.app]
# ============================================================

set -euo pipefail

APP_PATH="${1:-build/Release/Pier.app}"
DMG_NAME="Pier"
DMG_OUTPUT="build/${DMG_NAME}.dmg"
VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
DMG_OUTPUT="build/${DMG_NAME}-${VERSION}.dmg"

echo "==> Packaging DMG: $DMG_OUTPUT"

# Ensure the app exists
if [ ! -d "$APP_PATH" ]; then
    echo "❌ App not found at $APP_PATH"
    echo "   Run 'swift build -c release' first"
    exit 1
fi

# Remove old DMG if present
rm -f "$DMG_OUTPUT"

# Check for create-dmg
if command -v create-dmg &>/dev/null; then
    create-dmg \
        --volname "$DMG_NAME" \
        --volicon "$APP_PATH/Contents/Resources/AppIcon.icns" \
        --window-pos 200 100 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$DMG_NAME.app" 150 180 \
        --app-drop-link 450 180 \
        --hide-extension "$DMG_NAME.app" \
        --no-internet-enable \
        "$DMG_OUTPUT" \
        "$APP_PATH"
else
    echo "  create-dmg not found, using hdiutil fallback..."

    # Fallback: simple DMG with hdiutil
    STAGING="/tmp/pier-dmg-staging"
    rm -rf "$STAGING"
    mkdir -p "$STAGING"

    cp -R "$APP_PATH" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"

    hdiutil create \
        -volname "$DMG_NAME" \
        -srcfolder "$STAGING" \
        -ov \
        -format UDZO \
        "$DMG_OUTPUT"

    rm -rf "$STAGING"
fi

echo "==> DMG size: $(du -sh "$DMG_OUTPUT" | cut -f1)"

# Sign the DMG if identity available
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    echo "==> Signing DMG..."
    codesign --force --sign "${SIGNING_IDENTITY}" "$DMG_OUTPUT"
    echo "✅ DMG signed"
fi

echo "✅ DMG created: $DMG_OUTPUT"
