# 🚢 Pier Terminal

> A powerful macOS terminal manager built with Swift + Rust — inspired by XShell.
>
> 基于 Swift + Rust 的 macOS 终端管理工具 — 灵感来自 XShell。

---

## ✨ Features / 功能特性

### 🖥 Terminal Engine / 终端引擎
- VT100/ANSI terminal emulator (vte) — VT100/ANSI 终端模拟器
- PTY process management (forkpty) — PTY 进程管理
- Tab-based session management — 标签页会话管理

### 🔐 SSH & SFTP
- SSH connection (russh 0.57) with password & key auth — SSH 连接（密码/密钥认证）
- SFTP file operations (list / upload / download / delete) — SFTP 文件操作
- Remote file browser UI — 远程文件浏览器

### 📂 Local File Browser / 本地文件浏览
- Tree view with lazy loading — 懒加载树形视图
- Search & filter, drag-and-drop — 搜索过滤、拖拽支持
- Context menus — 右键菜单

### 📱 Right Panel (6 Modes) / 右侧面板（6 个模式）

| Mode / 模式 | Description / 描述 |
|---|---|
| 📝 Markdown | Preview `.md` files / 预览 Markdown 文件 |
| 📁 SFTP | Remote file browser / 远程文件管理 |
| 🐳 Docker | Container, image & volume management / 容器、镜像、卷管理 |
| 🌿 Git | Branch, staging, commit, push/pull, stash / 分支、暂存、提交、推拉、贮藏 |
| 🗄️ MySQL | SQL editor with tabular results / SQL 编辑器 + 表格化结果 |
| 📋 Logs | Real-time log tailing with level filtering / 实时日志追踪 + 级别过滤 |

### 🔒 Security / 安全
- AES-256-GCM encryption (ring) — AES-256-GCM 加密
- macOS Keychain credential storage — Keychain 凭据存储

### 🤖 AI Integration / AI 集成
- LLM service abstraction (OpenAI / Claude / Ollama) — 大模型服务抽象层

---

## 🏗 Architecture / 技术架构

```
┌─────────────────────────────────────────────┐
│              SwiftUI + AppKit               │  ← UI Layer / 界面层
├─────────────────────────────────────────────┤
│     ViewModels (MVVM) + Combine             │  ← Business Logic / 业务逻辑
├─────────────────────────────────────────────┤
│          pier-core (Rust via C FFI)         │  ← Core Engine / 核心引擎
├─────────────────────────────────────────────┤
│   PTY · SSH · SFTP · VTE · Crypto · Search  │  ← System APIs / 系统接口
└─────────────────────────────────────────────┘
```

| Layer / 层 | Tech / 技术 |
|---|---|
| UI | SwiftUI + AppKit (NSViewRepresentable) |
| Logic / 逻辑 | Swift, Combine, MVVM |
| Engine / 引擎 | Rust (C FFI via cbindgen) |
| Terminal / 终端 | vte 0.15 + forkpty |
| SSH/SFTP | russh 0.57 + russh-sftp 2.1 |
| Crypto / 加密 | ring (AES-256-GCM) |
| Search / 搜索 | ignore (ripgrep backend) |

---

## 🚀 Getting Started / 快速开始

### Prerequisites / 前置要求

- macOS 14.0+
- Xcode 16+ (Swift 6.x)
- Rust toolchain (`rustup`)

### Build / 构建

```bash
# 1. Clone
git clone git@github.com:chenqi92/Pier.git
cd Pier

# 2. Build Rust core / 构建 Rust 核心库
cd pier-core && cargo build --release && cd ..

# 3. Build & Run Swift app / 构建并运行 Swift 应用
swift build && .build/arm64-apple-macosx/debug/PierApp
```

### Xcode

1. Open `Package.swift` in Xcode / 用 Xcode 打开 `Package.swift`
2. Select scheme **PierApp** → **My Mac**
3. Press **⌘R** to run / 按 ⌘R 运行

---

## 📁 Project Structure / 项目结构

```
Pier/
├── pier-core/              # Rust core engine / Rust 核心引擎
│   └── src/
│       ├── terminal/       # VTE emulator + PTY / 终端模拟 + PTY
│       ├── ssh/            # SSH session + SFTP client
│       ├── search/         # File search (ignore crate)
│       ├── crypto/         # AES-256-GCM encryption
│       └── ffi/            # C FFI exports
├── pier-bridge/            # C module map for Swift-Rust FFI
├── PierApp/
│   ├── Info.plist          # Bundle ID: com.kkape.pier
│   └── Sources/
│       ├── App/            # App entry + AppDelegate
│       ├── Bridge/         # Swift FFI wrapper
│       ├── Models/         # Data models
│       ├── Services/       # Keychain, LLM
│       ├── ViewModels/     # MVVM ViewModels (7)
│       └── Views/          # SwiftUI views (8)
├── Package.swift           # Swift Package Manager config
├── FEATURES.md             # Feature status / 功能进度
└── README.md               # This file / 本文件
```

---

## 📋 Roadmap / 开发路线

See [FEATURES.md](./FEATURES.md) for the full feature status list.

查看 [FEATURES.md](./FEATURES.md) 获取完整功能进度。

**Next priorities / 下一步：**
- [ ] High-performance terminal rendering (Core Text / Metal)
- [ ] SSH connection manager UI
- [ ] Command auto-completion
- [ ] AI chat panel
- [ ] Dark/light theme switching

---

## 📄 License

MIT © 2026 [kkape.com](https://kkape.com)
