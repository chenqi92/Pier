#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# Pier Terminal — Clean Build & Launch Script
#
# 用法:
#   ./run.sh                    # 默认: debug + 清理 + 直接启动（无权限弹窗）
#   ./run.sh release            # release 模式
#   ./run.sh --no-clean         # 跳过清理，增量构建
#   ./run.sh --app              # 打包为 .app bundle 后启动（会触发 TCC 权限弹窗）
#
# 启动模式说明:
#   默认（开发模式）: 直接运行二进制，继承 Terminal.app 的权限，不弹窗
#   --app（发布模式）: 组装 .app bundle 并用 open 启动，macOS 会按 TCC 策略弹权限
# ═══════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

MODE="debug"
CLEAN=true
LAUNCH_APP=false

for arg in "$@"; do
    case "$arg" in
        release)    MODE="release" ;;
        --no-clean) CLEAN=false ;;
        --app)      LAUNCH_APP=true ;;
    esac
done

echo "🚀 Pier Terminal — Build & Launch (mode: $MODE, app-bundle: $LAUNCH_APP)"
echo ""

# ── Step 0: 终止已运行的实例 ──
if pgrep -x "PierApp" > /dev/null 2>&1; then
    echo "⏹  终止已运行的 PierApp..."
    pkill -x "PierApp" || true
    sleep 0.5
fi

# ── Step 1: 清理旧的构建产物 ──
if [ "$CLEAN" = true ]; then
    echo "🧹 清理旧的构建产物..."
    rm -rf .build
    rm -rf build
    (cd pier-core && cargo clean)
    echo "✅ 清理完成"
    echo ""
fi

# ── Step 2: 构建 Rust core ──
echo "📦 构建 pier-core (Rust)..."
cd pier-core

if [ "$MODE" = "release" ]; then
    cargo build --release
else
    cargo build
fi

echo "✅ Rust core 构建完成"
echo ""

cd "$SCRIPT_DIR"

# ── Step 3: 构建 Swift 应用 ──
echo "🍎 构建 PierApp (Swift)..."

if [ "$MODE" = "release" ]; then
    swift build -c release
    BIN_PATH=$(swift build -c release --show-bin-path)
else
    swift build
    BIN_PATH=$(swift build --show-bin-path)
fi

BINARY="$BIN_PATH/PierApp"
echo "✅ Swift 构建完成: $BINARY"
echo ""

# ── Step 4 & 5: 启动应用 ──
if [ "$LAUNCH_APP" = true ]; then
    # ── .app bundle 模式（发布/测试用）──
    APP_NAME="Pier Terminal"
    APP_BUNDLE="build/${APP_NAME}.app"

    echo "📁 组装 ${APP_NAME}.app bundle..."

    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"

    cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/PierApp"
    cp PierApp/Info.plist "$APP_BUNDLE/Contents/Info.plist"

    if [ -f "PierApp/Sources/Resources/AppIcon.icns" ]; then
        cp "PierApp/Sources/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
    fi

    RESOURCES_BUNDLE="$BIN_PATH/PierApp_PierApp.bundle"
    if [ -d "$RESOURCES_BUNDLE" ]; then
        cp -R "$RESOURCES_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    fi

    if [ -f "PierApp/PierApp.entitlements" ]; then
        codesign --force --sign - \
            --entitlements "PierApp/PierApp.entitlements" \
            "$APP_BUNDLE"
    fi

    echo "✅ App bundle 组装完成"
    echo ""
    echo "🎯 启动 ${APP_NAME}.app..."
    open "$APP_BUNDLE"
else
    # ── 开发模式：直接运行二进制（无权限弹窗）──
    echo "🎯 直接启动 PierApp（开发模式，无 TCC 弹窗）..."

    # 复制资源 bundle 到二进制同级目录（SPM 运行时从这里查找资源）
    RESOURCES_BUNDLE="$BIN_PATH/PierApp_PierApp.bundle"
    if [ -d "$RESOURCES_BUNDLE" ]; then
        echo "📂 资源 bundle: $RESOURCES_BUNDLE"
    fi

    # 使用 nohup 后台启动，日志输出到项目根目录
    LOG_FILE="$SCRIPT_DIR/pier_debug.log"
    nohup "$BINARY" > "$LOG_FILE" 2>&1 &
    LAUNCHED_PID=$!
    disown $LAUNCHED_PID

    echo ""
    echo "✅ PierApp 已在后台启动 (PID: $LAUNCHED_PID)"
    echo "   日志文件: $LOG_FILE"
    echo "   关闭此终端窗口不会影响应用运行"
fi
