# DSHMobile — DeepSeek Harness 的 iOS 客户端

纯 Swift / SwiftUI 实现的 [DSH（DeepSeek Harness）](https://github.com/deepseek-ai/dsh) iOS 客户端。
通过 DSH 的「远程设备」配对机制，在 iPhone / iPad 上获得与浏览器完全一致的 DSH 体验
（App 化 Web 壳 + 原生通知/灵动岛叠加）。

## 功能

- 🌐 **App 化 Web 壳主界面**：官方 DSH Web 即 App 主体——全屏沉浸式 WKWebView，
  无地址栏 / 无浏览器工具栏，顶部细进度条 + 下拉刷新；像拼多多那样的「网页内容 + App 体验」，
  web 的全部功能（会话 / 全部设置命名空间 / 凭证 / 模型管理…）一个不少
- 📱 **移动端响应式适配**：自动注入 viewport / 禁止缩放 / 防横向裁切 / 输入控件 16px 防聚焦放大 /
  触控目标 ≥40px，解决 iPhone 直访 web UI 拥挤、点不到、元素消失的问题
- 🔗 **配对连接**：用配对令牌换 deviceId，长期有效（配合服务器端永久令牌配置）；**支持扫码配对**——
  直接扫描配对链接的二维码即可完成，无需手输令牌；web 壳自动注入 dsh_pair 设备 cookie 复用配对身份
- 📶 **智能路由**：自动检测——同一 WiFi 下走局域网直连（低延迟），否则走公网中转（Cloudflare 隧道）
- ⚙️ **App 控制面板**：右下角悬浮齿轮打开——通知 / 灵动岛开关、会话级「特别关注」、服务器与配对、重新加载
- 🎯 **会话级「特别关注」**：每个会话可设 跟随全局 / 特别关注 / 静音——特别关注的会话前台也弹横幅，
  静音会话一律不打扰（灵动岛进度照常）
- 🔔 **本地通知**：围绕「需要处理」的一切——任务完成 / 运行失败 / 对话出现提问时推送（跟随后台会话 watcher）
- 🕐 **灵动岛 + 实时活动（Live Activity）**：任务运行期间在灵动岛 / 锁屏 / 通知中心实时显示生成进度
  （流式字符数 + 进度条），完成 / 取消自动收尾；设置里可开关
- 🧩 **Widget 扩展**：独立的 `DSHMobileWidgets` 扩展 target（ActivityConfiguration）承载灵动岛与锁屏 UI
- 🍎 **无需越狱**：产物是未签名 IPA，用 [SideStore](https://sidestore.io) 免费 Apple ID 重签安装
- 📱 **iOS 17+**：SwiftUI 原生实现，适配 iPhone 与 iPad

## 快速开始（用户）

1. **构建 / 获取 IPA**：GitHub Actions 每次 push 或手动触发后产出 `DSHMobile-unsigned-*.ipa`
2. **安装 SideStore**：安装到 iPhone/iPad（需要一台辅助 Mac/PC 跑 SideStore 或 AltServer）
3. **安装 App**：AirDrop / 文件 App 打开 `.ipa` → 选择 SideStore → 签名安装
4. **配对**：
   - 在 DSH 主机上执行 `node dsh-pair.cjs issue` 获取配对链接（或 DSH Web「设置 → 远程设备」添加设备）
   - App 里填写局域网地址（如 `http://192.168.0.142:3080`）与公网地址（如 `https://xxxx.dsh-market.com`）
   - 点击「扫描配对链接二维码」，扫电脑屏幕/手机上的配对链接二维码即可自动填入令牌并配对（也可手动粘贴令牌）
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
│   ├── Info.plist                 # 含 ATS（允许局域网明文 http）+ 相机权限
│   └── Assets.xcassets/           # 图标 / 主题色
├── DSHMobile/
│   ├── DSHMobileApp.swift         # App 入口 + 根视图分流（配对 → Web 壳）
│   ├── Models/
│   │   ├── DSHModels.swift        # 与 DSH 线上协议对齐的数据模型
│   │   └── AppSettings.swift      # 连接配置（地址/凭证/自动检测）+ 会话关注
│   ├── Networking/
│   │   ├── APIClient.swift        # HTTP JSON-RPC 客户端
│   │   └── StreamClient.swift     # WebSocket mux 流式客户端
│   ├── ViewModels/
│   │   └── ChatViewModel.swift    # 无头 follow 流引擎（通知/灵动岛驱动）
│   ├── Support/
│   │   ├── NotificationManager.swift # 本地通知 + 通知点击路由
│   │   ├── ActivityManager.swift     # 实时活动（灵动岛）管理器
│   │   └── SessionWatcher.swift      # 后台会话跟随器（轮询运行中会话）
│   └── Views/
│       ├── SetupView.swift        # 配对 / 服务器设置（含扫码配对）
│       ├── QRScannerView.swift    # VisionKit 二维码扫描（配对用）
│       ├── WebConsoleView.swift   # App 主界面：WKWebView 承载官方 DSH Web + 移动端适配
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

## License

MIT
