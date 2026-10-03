# DSHMobile — DeepSeek Harness 的 iOS 客户端

纯 Swift / SwiftUI 实现的 [DSH（DeepSeek Harness）](https://github.com/deepseek-ai/dsh) iOS 客户端。
通过 DSH 的「远程设备」配对机制，在 iPhone / iPad 上获得与浏览器一致的 DSH 体验，
**对话流用官方 DSH Web 承载、按键用原生**：会话列表 / 对话流 / 工具结果由嵌入式官方 Web 控制台渲染，
与网页端状态完全一致；原生层只补「按键」——顶栏（模式 / 模型 / 会话权限 / 设置）与
底部输入条（文本 / 语音 / 附件 / 发送·插话 / 停止），并叠加通知、灵动岛等系统能力。

## 功能

- 🖥️ **主界面：网页承载对话流 + 原生按键**
  - 会话列表、消息流、思考过程、工具调用、流式输出全部由嵌入式官方 DSH Web 控制台渲染，
    与网页端同一份 UI 状态 —— 不会出现「App 里多出网页没有的会话」或「重复的历史消息」
  - **原生顶栏**：会话抽屉 + 当前会话标题 + 运行中指示 + 模式（Agent 预设）/ 模型 / 会话权限 / 新建会话 / 设置
  - **原生会话抽屉**：窄屏下官方侧栏会收成 56px 轨道、行还会被虚拟化，手机很难点；抽屉用官方 RPC
    渲染一份原生会话列表（运行中置顶、按工作区分组、时间、特别关注、重命名），点一下就在网页里打开
  - **原生底部输入条**：文本输入、**语音输入**（SFSpeechRecognizer）、**添加文件**、
    **添加照片**（PhotosPicker）、**命令面板**（`commands/list`，与网页斜杠命令同源）、
    发送（生成中自动转为 **steer 插话**）、停止生成
  - **输入框永久不变式**：网页自带输入条只在原生输入条**确实在屏幕上**时才被隐藏
    （同一段 JS 的同一次判定同时决定「原生条显示」与「网页条隐藏」），
    因此桥接任何一环失败都只会退回网页输入条，**绝不会出现「一个输入框都没有」**
  - 原生栏用真实布局（VStack）分段，不需要任何 CSS 高度补偿
- 🛟 **网页自愈**：渲染进程被系统回收 / 崩溃时自动重载（连续 3 次才报错），
  任何加载失败都给「重试」，抽屉与设置里都有「重新加载网页」
- 📨 **通知直接开会话**：点「完成 / 失败 / 提问」通知会在网页里打开对应会话，而不是只把 App 带回前台
- 🧱 **完整原生实现仍保留在源码中**：`SessionListView` + `ChatView` 是一套纯原生会话列表 / 聊天界面
  （流式、思考折叠、工具胶囊、模式 / 模型 / 权限、附件、插话、智能自动滚动），
  目前不再作为默认入口，可作为无 Web 环境的备用实现
- 🌐 **Web 控制台**：完整官方 DSH Web（会话 · 设置 · 凭证 · 模型管理…全功能）以 WKWebView 嵌入，
  移动端响应式适配（viewport / 防裁切 / 16px 输入 / 触控目标 / 安全区）+ 新窗口链接壳内打开
- 🔗 **配对连接**：用配对令牌换 deviceId，长期有效（配合服务器端永久令牌配置）；**支持扫码配对**——
  直接扫描配对链接的二维码即可完成，无需手输令牌；配对后自动向服务器请求回局域网/公网地址补全
- 📶 **智能路由**：自动检测——同一 WiFi 下走局域网直连（低延迟），否则走公网中转（Cloudflare 隧道）
- ⚙️ **App 设置（原生）**：通知 / 灵动岛开关、会话级「特别关注」、服务器与配对、Web 组件入口
- 🎯 **会话级「特别关注」**：每个会话可设 跟随全局 / 特别关注 / 静音——特别关注的会话前台也弹横幅，
  静音会话一律不打扰（灵动岛进度照常）
- 🔔 **本地通知**：围绕「需要处理」的一切——任务完成 / 运行失败 / 对话出现提问时推送（跟随后台会话 watcher）
- 🕐 **灵动岛 + 实时活动（Live Activity）**：任务运行期间在灵动岛 / 锁屏 / 通知中心实时显示生成进度
  （**真实上下文占用进度**——来自服务端 contextPressure 投影的 contextWindow 与占用估算，缺失时回落字符启发式；
  **会话累计 token 消耗**——来自 tokenUsage 投影，输出 / 总计实时更新），
  **长按展开可看到当前步骤**——正在运行命令 / 搜索网页 / 读取文件 / 思考中 / 等待授权，
  完成 / 取消自动收尾；设置里可开关
- 🧩 **Widget 扩展**：独立的 `DSHMobileWidgets` 扩展 target（ActivityConfiguration）承载灵动岛与锁屏 UI
- 🍎 **无需越狱**：产物是未签名 IPA，用 [SideStore](https://sidestore.io) 免费 Apple ID 重签安装
- 📱 **iOS 17+**：SwiftUI 原生实现，适配 iPhone 与 iPad

## 快速开始（用户）

1. **构建 / 获取 IPA**：GitHub Actions 每次 push 或手动触发后产出 `DSHMobile-unsigned-*.ipa`
2. **安装 SideStore**：安装到 iPhone/iPad（需要一台辅助 Mac/PC 跑 SideStore 或 AltServer）
3. **安装 App**：AirDrop / 文件 App 打开 `.ipa` → 选择 SideStore → 签名安装
4. **配对**：
   - 在 DSH 主机上执行 `node dsh-pair.cjs issue` 获取配对链接（或 DSH Web「设置 → 远程设备」添加设备）
   - App 里填写局域网地址（如 `http://192.168.1.100:3080`，`192.168.1.100` 是示例，请填 DSH 主机在 WiFi 下的实际 IP）与公网地址（如 `https://xxxx.dsh-market.com`）
   - 点击「扫描配对链接二维码」，扫电脑屏幕/手机上的配对链接二维码即可自动填入令牌并配对（也可手动粘贴令牌）
   - 扫码配对后 App 会向服务器请求回局域网/公网地址并自动补全，一次配好双地址
5. 开始对话 🎉

> 免费 Apple ID 的证书 7 天过期，需要在 SideStore 里重新签名；同时最多装 3 个自签 App。

## 技术栈

- **SwiftUI**（iOS 17.0+ 部署目标，支持最新 iOS）
- **ActivityKit / UserNotifications**：本地实时活动（灵动岛 + 锁屏）+ 本地通知；免费签名无 APNs，全部走本地更新
- **XcodeGen**：`project.yml` 是工程唯一事实来源，`.xcodeproj` 由 `xcodegen generate` 生成
- **纯 URLSession**：HTTP JSON-RPC + WebSocket 流式，零第三方依赖
- **GitHub Actions**：`macos-latest` runner 自动挑最新 Xcode 出未签名 IPA

## 开发者

```bash
# 生成工程
xcodegen generate --spec project.yml

# 本机验证（不需要 iOS SDK）：语法 / 配置 / 图标，有 Xcode 时顺带完整编译
./scripts/verify-all.sh

# 构建未签名 IPA（需要完整 Xcode + xcodegen）
./scripts/make-unsigned-ipa.sh
```

### 目录结构

```
DSHMobile/
├── project.yml                    # XcodeGen 工程描述（唯一事实来源）
├── Resources/
│   ├── Info.plist                 # 含 ATS（允许局域网明文 http）+ 相机/语音/麦克风权限
│   └── Assets.xcassets/           # 图标 / 主题色
├── DSHMobile/
│   ├── DSHMobileApp.swift         # App 入口 + 根视图分流（配对 → WebChatShellView）
│   ├── Models/
│   │   ├── DSHModels.swift        # 与 DSH 线上协议对齐的数据模型 + 投影便利
│   │   └── AppSettings.swift      # 连接配置（地址/凭证/自动检测）+ 会话关注
│   ├── Networking/
│   │   ├── APIClient.swift        # HTTP JSON-RPC 客户端（含 agentPresets/modelCatalog/权限/fork）
│   │   └── StreamClient.swift     # WebSocket mux 流式客户端
│   ├── ViewModels/
│   │   └── ChatViewModel.swift    # follow 流引擎（消息/流式/token/通知/灵动岛）
│   ├── Support/
│   │   ├── NotificationManager.swift # 本地通知 + 通知点击路由
│   │   ├── ActivityManager.swift     # 实时活动（灵动岛）管理器
│   │   ├── SessionWatcher.swift      # 后台会话跟随器（轮询运行中会话）
│   │   └── SpeechRecognizer.swift    # 语音输入（SFSpeechRecognizer + AVAudioEngine）
│   └── Views/
│       ├── WebChatShellView.swift # 主界面：网页控制台承载对话流 + 原生顶栏/输入条
│       ├── SessionDrawer.swift    # 原生会话抽屉（打开/新建/关注/重命名/重新加载）
│       ├── SessionListView.swift  # 原生会话列表（备用：token/权限/关注/新建/重命名/fork）
│       ├── ChatView.swift         # 原生聊天（备用：流式/思考/工具/语音/模式/模型切换）
│       ├── AppSettingsView.swift  # 原生 App 设置面板
│       ├── SetupView.swift        # 配对 / 服务器设置（含扫码配对）
│       ├── QRScannerView.swift    # VisionKit 二维码扫描（配对用）
│       ├── WebConsoleView.swift   # WKWebView 承载官方 DSH Web + 移动端适配 + 会话/阶段回传
│       └── WebShellControlSheet.swift # App 控制面板（通知/灵动岛/会话关注）
├── DSHMobileWidgets/              # 灵动岛 / 锁屏 Widget 扩展
│   ├── TaskProgressAttributes.swift
│   └── TaskProgressLiveActivity.swift
├── scripts/
│   ├── make-unsigned-ipa.sh       # 未签名 IPA 构建
│   └── verify-all.sh              # 本机验证套件
└── .github/workflows/build-ipa.yml
```

## 传输协议

客户端通过 DSH 官方「远程设备」通道通信：

- **HTTP RPC**：`POST {base}/remote/api/<endpoint>`，请求 `{"rpcId","method","payload"}`，设备凭证为请求头 `x-dsh-remote-device`
- **流式**：WebSocket `{base}/remote/api/remote.mux?device=<id>`，上行 `open/item/end/cancel` 帧，下行 `item/end/error` 帧
- **历史/实时**：`session.follow` 流先给快照再持续推事件（`user/message`、`assistant/message`、`assistant-stream` 帧等）

## 协议与规范

- [DSH](https://github.com/deepseek-ai/dsh)
- [SideStore](https://sidestore.io)

## 版本

当前 **1.0**（`MARKETING_VERSION` / `CFBundleShortVersionString`）；变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## License

MIT
