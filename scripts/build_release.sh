#!/bin/bash
# ============================================================
# Pier — CI Release Build Script
# ============================================================
# Builds a release .app bundle with the version from VERSION file
# injected into Info.plist.
#
# Usage:
#   ./scripts/build_release.sh
#
# Output:
#   build/Pier.app  — ready-to-distribute macOS app bundle
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# ── Read version from VERSION file ──
VERSION=$(cat VERSION | tr -d '[:space:]')
if [ -z "$VERSION" ]; then
    echo "❌ VERSION file is empty"
    exit 1
fi

echo "🔧 Building Pier Terminal v${VERSION} (release)..."
echo ""

# ── Step 1: Build Rust core library ──
echo "📦 Building pier-core (Rust)..."
cd pier-core
cargo build --release
echo "✅ Rust core built"
cd "$PROJECT_DIR"

# ── Step 2: Build Swift application ──
echo ""
echo "🍎 Building PierApp (Swift)..."
swift build -c release
BIN_PATH=$(swift build -c release --show-bin-path)
BINARY="$BIN_PATH/PierApp"
echo "✅ Swift built: $BINARY"

# ── Step 3: Inject version into Info.plist ──
echo ""
echo "📝 Injecting version ${VERSION} into Info.plist..."
PLIST="$PROJECT_DIR/PierApp/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"

# Generate build number from git commit count
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo "1")
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$PLIST"

echo "   Version: ${VERSION} (build ${BUILD_NUMBER})"

# ── Step 4: Assemble .app bundle ──
echo ""
echo "📁 Assembling Pier.app bundle..."

APP_BUNDLE="$PROJECT_DIR/build/Pier.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/PierApp"

# Copy Info.plist
cp "$PLIST" "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon
if [ -f "PierApp/Sources/Resources/AppIcon.icns" ]; then
    cp "PierApp/Sources/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

# Copy SPM resource bundle
RESOURCES_BUNDLE="$BIN_PATH/PierApp_PierApp.bundle"
if [ -d "$RESOURCES_BUNDLE" ]; then
    cp -R "$RESOURCES_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

# Ad-hoc sign (no developer certificate)
codesign --force --sign - "$APP_BUNDLE" 2>/dev/null || true

echo "✅ App bundle assembled: $APP_BUNDLE"

# ── Step 5: Create DMG ──
echo ""
echo "📀 Creating DMG..."

DMG_OUTPUT="$PROJECT_DIR/build/Pier-${VERSION}.dmg"
rm -f "$DMG_OUTPUT"

STAGING="/tmp/pier-dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"

cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Pier Terminal" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUTPUT"

rm -rf "$STAGING"

echo "✅ DMG created: $DMG_OUTPUT ($(du -sh "$DMG_OUTPUT" | cut -f1))"
echo ""
echo "🎉 Release build complete!"
echo "   App:  $APP_BUNDLE"
echo "   DMG:  $DMG_OUTPUT"
