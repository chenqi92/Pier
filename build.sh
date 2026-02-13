#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# Pier Terminal — Build Script
# Builds Rust core library, then the Swift application.
# ═══════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

MODE="${1:-debug}"

echo "🔧 Building Pier Terminal (mode: $MODE)..."

# ── Step 1: Build Rust core library ──
echo ""
echo "📦 Building pier-core (Rust)..."
cd pier-core

if [ "$MODE" = "release" ]; then
    cargo build --release
    RUST_TARGET_DIR="target/release"
else
    cargo build
    RUST_TARGET_DIR="target/debug"
fi

echo "✅ Rust core built: $RUST_TARGET_DIR/libpier_core.a"

# ── Step 2: Generate C header (cbindgen) ──
echo ""
echo "📝 C header generated at pier-bridge/include/pier_core.h"

cd "$SCRIPT_DIR"

# ── Step 3: Build Swift application ──
echo ""
echo "🍎 Building PierApp (Swift)..."

if [ "$MODE" = "release" ]; then
    swift build -c release
else
    swift build
fi

echo ""
echo "✅ Build complete!"
echo ""

# Show binary location
if [ "$MODE" = "release" ]; then
    BINARY=$(swift build -c release --show-bin-path)/PierApp
else
    BINARY=$(swift build --show-bin-path)/PierApp
fi
echo "📍 Binary: $BINARY"
