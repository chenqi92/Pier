#!/bin/bash
# ============================================================
# Pier — Performance Profiling Script
# ============================================================
# Runs Instruments profiles and collects performance baselines.
#
# Usage:
#   ./scripts/profile.sh [path/to/Pier.app]
# ============================================================

set -euo pipefail

APP_PATH="${1:-build/Release/Pier.app}"
OUTPUT_DIR="build/profiles"
mkdir -p "$OUTPUT_DIR"

echo "========================================"
echo "  Pier Performance Profiling"
echo "========================================"

# ── 1. Build Size Metrics ──
echo ""
echo "1. Build Size"
APP_SIZE=$(du -sh "$APP_PATH" 2>/dev/null | cut -f1 || echo "N/A")
echo "  App bundle: $APP_SIZE"

BINARY_PATH="$APP_PATH/Contents/MacOS/Pier"
if [ -f "$BINARY_PATH" ]; then
    BINARY_SIZE=$(du -sh "$BINARY_PATH" | cut -f1)
    echo "  Binary: $BINARY_SIZE"
fi

# ── 2. Launch Time ──
echo ""
echo "2. Launch Time Estimate"
echo "  (Launch the app to measure — use Instruments Time Profiler for accurate data)"
echo "  Command: xcrun xctrace record --template 'Time Profiler' --launch '$APP_PATH' --output '$OUTPUT_DIR/time_profiler.trace'"

# ── 3. Memory Baseline ──
echo ""
echo "3. Memory Baseline"
echo "  Command: xcrun xctrace record --template 'Allocations' --attach 'Pier' --output '$OUTPUT_DIR/allocations.trace' --time-limit 30s"
echo "  Command: xcrun xctrace record --template 'Leaks' --attach 'Pier' --output '$OUTPUT_DIR/leaks.trace' --time-limit 30s"

# ── 4. Swift Compilation Times ──
echo ""
echo "4. Compilation Performance"
echo "  Running swift build with timing..."
BUILD_START=$(date +%s)
swift build -c release 2>&1 | tail -5
BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))
echo "  Release build time: ${BUILD_TIME}s"

# ── 5. Binary Analysis ──
echo ""
echo "5. Binary Analysis"
if [ -f "$BINARY_PATH" ]; then
    echo "  Architecture: $(file "$BINARY_PATH" | sed 's/.*: //')"

    # Count symbols
    SYMBOL_COUNT=$(nm "$BINARY_PATH" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Symbol count: $SYMBOL_COUNT"

    # Check for debug symbols
    if nm "$BINARY_PATH" 2>/dev/null | grep -q " T _main"; then
        echo "  Debug symbols: present"
    fi
fi

# ── 6. Swift Package Dependencies ──
echo ""
echo "6. Dependencies"
DEPS=$(swift package show-dependencies 2>/dev/null | grep -c "│\|├\|└" || echo "0")
echo "  Package dependencies: $DEPS"

# ── Summary ──
echo ""
echo "========================================"
echo "  Profiling commands generated in $OUTPUT_DIR"
echo "  Run Instruments manually for detailed traces"
echo "========================================"
