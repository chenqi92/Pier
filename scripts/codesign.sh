#!/bin/bash
# ============================================================
# Pier — Code Signing & Notarization Script
# ============================================================
# Usage:
#   ./scripts/codesign.sh [--notarize]
#
# Required environment variables:
#   TEAM_ID          — Apple Developer Team ID
#   SIGNING_IDENTITY — e.g. "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID         — Apple ID email for notarization
#   APP_PASSWORD     — App-specific password for notarization
# ============================================================

set -euo pipefail

APP_PATH="${1:-build/Release/Pier.app}"
BUNDLE_ID="com.chenqi.pier"

echo "==> Code Signing: $APP_PATH"

# 1. Deep sign with hardened runtime
codesign \
    --deep \
    --force \
    --options runtime \
    --entitlements scripts/Pier.entitlements \
    --sign "${SIGNING_IDENTITY}" \
    --timestamp \
    "$APP_PATH"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"
echo "✅ Code signing verified"

# 2. Notarization (optional)
if [[ "${1:-}" == "--notarize" || "${2:-}" == "--notarize" ]]; then
    echo "==> Notarizing..."

    # Create ZIP for upload
    ARCHIVE="/tmp/Pier-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE"

    # Submit to Apple
    xcrun notarytool submit "$ARCHIVE" \
        --apple-id "${APPLE_ID}" \
        --password "${APP_PASSWORD}" \
        --team-id "${TEAM_ID}" \
        --wait

    # Staple the notarization ticket
    xcrun stapler staple "$APP_PATH"
    echo "✅ Notarization complete and stapled"

    rm -f "$ARCHIVE"
fi

echo "==> Done"
