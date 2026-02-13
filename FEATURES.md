# Pier Terminal — 功能进度

> macOS 终端管理工具 · Bundle ID: `com.kkape.pier`

## ✅ 已完成功能

### 🏗 基础架构
- [x] Swift + Rust 混合架构（SPM + Cargo）
- [x] Rust 核心库（pier-core）编译通过，8 个单元测试通过
- [x] C FFI 桥接层（cbindgen 自动生成头文件）
- [x] Swift 桥接封装（RustBridge.swift）
- [x] 三栏布局框架（HSplitView）
- [x] MVVM 架构 + Combine 响应式绑定

### 🖥 终端引擎（Rust）
- [x] VT100/ANSI 终端模拟器（vte 0.15）
- [x] PTY 进程管理（forkpty + 非阻塞 IO）
- [x] 终端会话创建 / 销毁 / 读写 / 调整大小 FFI

### 🔐 SSH / SFTP（Rust）
- [x] SSH 连接管理（russh 0.57）
- [x] 密码认证 / 密钥认证
- [x] SFTP 文件操作（列目录 / 上传 / 下载 / 删除 / 创建目录）
- [x] 远程文件浏览器 UI

### 🔍 文件系统
- [x] 本地文件搜索引擎（ignore crate，兼容 .gitignore）
- [x] 目录列表 FFI
- [x] 本地文件树浏览器（懒加载 + 搜索过滤 + 右键菜单 + 拖拽）
- [x] 文件系统监控（DispatchSource）

### 🔒 安全
- [x] AES-256-GCM 加密/解密（ring crate）
- [x] macOS Keychain 凭据存储

### 📱 右侧面板（6 个模式）
- [x] **Markdown 预览** — AttributedString 渲染
- [x] **SFTP 文件管理** — 远程目录浏览 + 文件传输进度
- [x] **Docker 管理** — 容器/镜像/Volumes 管理，启动/停止/重启/删除/日志
- [x] **Git 面板** — 分支状态、暂存区、提交历史、Stash、Push/Pull
- [x] **MySQL 客户端** — 连接管理、表浏览、SQL 编辑器、表格化结果
- [x] **日志查看器** — 实时追踪(tail -f)、日志级别着色、文本过滤

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

### 🖥 终端渲染（高优先级）
- [ ] Core Text / Metal 高性能终端文本渲染
- [ ] 终端颜色主题（ANSI 256 色 / TrueColor）
- [ ] 光标闪烁动画
- [ ] 文本选择与复制
- [ ] 终端滚回缓冲区（scrollback buffer）
- [ ] URL 自动检测与点击

### 🔗 SSH 增强
- [ ] SSH Agent Forwarding
- [ ] SSH Known Hosts 验证
- [ ] SSH 连接管理器 UI（保存的服务器列表）
- [ ] SSH 隧道 / 端口转发
- [ ] SSH 密钥管理界面

### 📝 命令行增强
- [ ] 命令自动补全（路径 / 命令 / 参数）
- [ ] 命令历史搜索（Ctrl+R）
- [ ] 智能提示与语法高亮

### 🤖 AI 增强
- [ ] LLM 流式响应
- [ ] 命令生成与解释
- [ ] Shell 错误智能分析
- [ ] AI 聊天面板 UI

### 🎨 UI / UX 优化
- [ ] Markdown 渲染升级（代码块高亮、表格、图片）
- [ ] 深色/浅色主题切换
- [ ] 字体大小与字体选择
- [ ] 分栏宽度可调 + 记忆
- [ ] 窗口状态持久化
- [ ] 快捷键全面配置

### 📦 Docker 增强
- [ ] Docker Compose 支持
- [ ] 容器资源监控（CPU / 内存）
- [ ] 容器网络管理
- [ ] 镜像构建

### 🗄️ 数据库增强
- [ ] SQL 语法高亮
- [ ] 查询历史记录
- [ ] 表结构可视化（ER 图）
- [ ] 数据导出（CSV / JSON）
- [ ] PostgreSQL / SQLite 支持

### 🌿 Git 增强
- [ ] Diff 可视化（inline / side-by-side）
- [ ] 分支图可视化
- [ ] Blame 视图
- [ ] Merge 冲突解决器

### 📋 日志增强
- [ ] 多文件同时监控
- [ ] JSON 日志格式化
- [ ] 正则表达式过滤
- [ ] 日志导出

### 🚀 发布准备
- [ ] 代码签名 & 公证
- [ ] 自动更新（Sparkle）
- [ ] 安全审计
- [ ] 性能分析 & 优化
- [ ] DMG 打包

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
| 外部工具 | docker CLI, git CLI, mysql CLI |
