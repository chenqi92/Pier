# Pier Terminal — 功能进度

> macOS 终端管理工具 · Bundle ID: `com.kkape.pier`

---

## 🧭 产品定位

Pier 是一个面向服务器运维场景的 macOS 终端工具。核心价值：

**通过 SSH 连接到远程服务器后，自动探测服务器上安装的服务（MySQL、Redis、Docker 等），提供可视化操作面板 — 解决这些服务端口不对外开放、无法使用远程 GUI 客户端的问题。**

---

## 📐 架构设计

### 右侧面板工具分类

右侧面板的工具按 **运行上下文** 分为两类：

#### 🌐 远程上下文工具（需要活跃的 SSH 连接）

这些工具 **依赖当前 SSH 会话**，通过 SSH 隧道或远程命令访问服务器上的服务。解决的核心问题：服务端口仅监听 `127.0.0.1`，外部无法直接连接。

| 工具 | 远程探测方式 | 访问方式 |
|------|-------------|---------|
| **MySQL 客户端** | `which mysql && mysql --version` | SSH 隧道(L3306) → 本地连接 |
| **Redis 客户端** | `which redis-cli && redis-cli ping` | SSH 隧道(L6379) → 本地连接 |
| **PostgreSQL 客户端** | `which psql && psql --version` | SSH 隧道(L5432) → 本地连接 |
| **Docker 管理** | `which docker && docker info` | SSH exec → 远程 docker CLI |
| **日志查看器** | 检查常见日志路径 | SSH exec → `tail -f` |
| **SFTP 文件管理** | SFTP 子系统 | SSH → SFTP channel |

**工作流程**:
1. 用户通过 SSH 连接到服务器
2. Pier 自动在远程执行服务发现脚本
3. 右侧面板仅显示该服务器上 **实际可用** 的工具标签
4. 工具通过 SSH 隧道或 SSH exec 与远程服务交互

#### 💻 本地上下文工具（无需 SSH 连接）

这些工具在本地运行，不依赖远程服务器。

| 工具 | 说明 |
|------|------|
| **Markdown 预览** | 本地 .md 文件预览与渲染 |
| **Git 面板** | 本地 Git 仓库状态、提交、分支管理 |

---

## ✅ 已完成功能

### 🏗 基础架构
- [x] Swift + Rust 混合架构（SPM + Cargo）
- [x] Rust 核心库（pier-core）编译通过，8 个单元测试通过
- [x] C FFI 桥接层（cbindgen 自动生成头文件）
- [x] Swift 桥接封装（RustBridge.swift）
- [x] 三栏布局框架（HSplitView）
- [x] MVVM 架构 + Combine 响应式绑定
- [x] 统一命令执行器（CommandRunner actor）

### 🌍 国际化（i18n）
- [x] SPM 本地化配置（`defaultLocalization: "en"` + `.process("Resources")`）
- [x] 英文本地化（`en.lproj/Localizable.strings` — 80 键值）
- [x] 简体中文本地化（`zh-Hans.lproj/Localizable.strings` — 80 键值）
- [x] 全部 8 个 Swift 视图文件使用本地化键（Text/Button/.help）

### 🖥 终端引擎（Rust）
- [x] VT100/ANSI 终端模拟器（vte 0.15）
- [x] PTY 进程管理（forkpty + 非阻塞 IO）
- [x] 终端会话创建 / 销毁 / 读写 / 调整大小 FFI

### 🔐 SSH / SFTP（Rust）
- [x] SSH 连接管理（russh 0.57）
- [x] 密码认证 / 密钥认证
- [x] SFTP 文件操作（列目录 / 上传 / 下载 / 删除 / 创建目录）

### 🔍 文件系统
- [x] 本地文件搜索引擎（ignore crate，兼容 .gitignore）
- [x] 目录列表 FFI
- [x] 本地文件树浏览器（懒加载 + 搜索过滤 + 右键菜单 + 拖拽）
- [x] 文件系统监控（DispatchSource）

### 🔒 安全
- [x] AES-256-GCM 加密/解密（ring crate）
- [x] macOS Keychain 凭据存储（API Key + SSH 密码）

### 📱 右侧面板 UI（框架已就绪，待集成远程上下文）
- [x] 面板标签切换框架
- [x] Markdown 预览 UI（本地文件，AttributedString 渲染）
- [x] Docker 管理 UI（容器/镜像/Volumes）
- [x] Git 面板 UI（分支状态、提交历史、Stash）
- [x] MySQL 客户端 UI（表浏览、SQL 编辑器、表格化结果）
- [x] 日志查看器 UI（日志级别着色、文本过滤）

### 🤖 AI 集成
- [x] LLM 服务抽象（OpenAI / Claude / Ollama 接口）
- [x] 终端上下文感知的 AI 对话框架

### 🖼 UI 框架
- [x] 终端标签页管理（创建 / 切换 / 关闭）
- [x] 主窗口工具栏 + 状态栏
- [x] 拖拽文件到终端（路径注入）
- [x] 右键上下文菜单

---

## 🔲 待完成功能

### 🌐 远程服务发现与隧道（核心特性，高优先级）
- [x] SSH 连接后 **自动探测** 远程服务器已安装的服务
- [x] SSH 本地端口转发（`-L` 隧道），用于 MySQL/Redis/PostgreSQL
- [x] 右侧面板 **动态标签**：仅显示已探测到的服务
- [x] 远程服务状态指示器（运行中 / 已停止 / 未安装）

### 🗄️ 数据库客户端（远程上下文）
- [x] 通过 SSH 隧道连接远程 MySQL（`127.0.0.1:转发端口`）
- [x] Redis 客户端（`redis-cli` 交互 / 键值浏览 / TTL 管理）
- [x] PostgreSQL 客户端
- [x] SQLite 本地客户端（本地上下文）
- [x] SQL 语法高亮
- [x] 查询历史记录
- [x] 表结构可视化（ER 图）
- [x] 数据导出（CSV / JSON）

### 🖥 终端渲染（高优先级）
- [x] Core Text / Metal 高性能终端文本渲染
- [x] 终端颜色主题（ANSI 256 色 / TrueColor）
- [x] 光标闪烁动画
- [x] 文本选择与复制
- [x] 终端滚回缓冲区（scrollback buffer）
- [x] URL 自动检测与点击

### 🔗 SSH 增强
- [x] SSH Agent Forwarding
- [x] SSH Known Hosts 验证
- [x] SSH 连接管理器 UI（保存的服务器列表）
- [x] SSH 隧道 / 端口转发管理 UI
- [x] SSH 密钥管理界面

### 📦 Docker 增强（远程上下文）
- [x] 通过 SSH exec 执行远程 docker 命令
- [x] Docker Compose 支持
- [x] 容器资源监控（CPU / 内存）
- [x] 容器网络管理
- [x] 容器实时日志（通过 SSH 的 `docker logs -f`）

### 📋 日志增强（远程上下文）
- [x] 通过 SSH 追踪远程日志文件
- [x] 多文件同时监控
- [x] JSON 日志格式化
- [x] 正则表达式过滤
- [x] 日志导出

### 📝 命令行增强
- [x] 命令自动补全（路径 / 命令 / 参数）
- [x] 命令历史搜索（Ctrl+R）
- [x] 智能提示与语法高亮

### 🤖 AI 增强
- [x] LLM 流式响应
- [x] 命令生成与解释
- [x] Shell 错误智能分析
- [x] AI 聊天面板 UI

### 🎨 UI / UX 优化
- [x] Markdown 渲染升级（代码块高亮、表格、图片）
- [x] 深色/浅色主题切换
- [x] 字体大小与字体选择
- [x] 分栏宽度可调 + 记忆
- [x] 窗口状态持久化
- [x] 快捷键全面配置

### 🌿 Git 增强（本地上下文）
- [x] Diff 可视化（inline / side-by-side）
- [x] 分支图可视化
- [x] Blame 视图
- [x] Merge 冲突解决器

### 🚀 发布准备
- [x] 代码签名 & 公证
- [x] 自动更新（Sparkle）
- [x] 安全审计
- [x] 性能分析 & 优化
- [x] DMG 打包

---

## 📊 技术栈

| 层级 | 技术 |
|---|---|
| UI | SwiftUI + AppKit (NSViewRepresentable) |
| 业务逻辑 | Swift, Combine, MVVM |
| 核心引擎 | Rust (via C FFI) |
| 终端 | vte + forkpty |
| SSH/SFTP | russh 0.57 + russh-sftp 2.1 |
| 加密 | ring (AES-256-GCM) |
| 文件搜索 | ignore (ripgrep 同源) |
| 命令执行 | CommandRunner actor (统一路径解析 + 异步) |
