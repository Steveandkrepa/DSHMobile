# DSHMobile — DeepSeek Harness 的 iOS 客户端

纯 Swift / SwiftUI 实现的 [DSH（DeepSeek Harness）](https://github.com/deepseek-ai/dsh) Web 界面客户端。
通过 DSH 的「远程设备」配对机制，在 iPhone / iPad 上直接连接你的 DSH Web 实例并聊天。

## 功能

- 🔗 **配对连接**：用配对令牌换 deviceId，长期有效（配合服务器端永久令牌配置）
- 📶 **智能路由**：自动检测——同一 WiFi 下走局域网直连（低延迟），否则走公网中转（Cloudflare 隧道）
- 💬 **实时聊天**：基于 DSH 的 WebSocket mux 流式协议，流式增量渲染（支持思考过程折叠 / 工具调用展示）
- 📋 **会话管理**：浏览历史会话、新建会话、取消生成
- 🍎 **无需越狱**：产物是未签名 IPA，用 [SideStore](https://sidestore.io) 免费 Apple ID 重签安装
- 📱 **iOS 17+**：SwiftUI 原生实现，适配 iPhone 与 iPad

## 快速开始（用户）

1. **构建 / 获取 IPA**：GitHub Actions 每次 push 或手动触发后产出 `DSHMobile-unsigned-*.ipa`
2. **安装 SideStore**：安装到 iPhone/iPad（需要一台辅助 Mac/PC 跑 SideStore 或 AltServer）
3. **安装 App**：AirDrop / 文件 App 打开 `.ipa` → 选择 SideStore → 签名安装
4. **配对**：
   - 在 DSH 主机上执行 `node dsh-pair.cjs issue` 获取配对链接（或 DSH Web「设置 → 远程设备」添加设备）
   - App 里填写局域网地址（如 `http://192.168.0.142:3080`）与公网地址（如 `https://xxxx.dsh-market.com`），粘贴令牌配对
5. 开始对话 🎉

> 免费 Apple ID 的证书 7 天过期，需要在 SideStore 里重新签名；同时最多装 3 个自签 App。

## 技术栈

- **SwiftUI**（iOS 17.0+ 部署目标，支持最新 iOS）
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
│   ├── Info.plist                 # 含 ATS（允许局域网明文 http）
│   └── Assets.xcassets/           # 图标 / 主题色
├── DSHMobile/
│   ├── DSHMobileApp.swift         # App 入口 + 根视图分流
│   ├── Models/
│   │   ├── DSHModels.swift        # 与 DSH 线上协议对齐的数据模型
│   │   └── AppSettings.swift      # 连接配置（地址/凭证/自动检测）
│   ├── Networking/
│   │   ├── APIClient.swift        # HTTP JSON-RPC 客户端
│   │   └── StreamClient.swift     # WebSocket mux 流式客户端
│   ├── ViewModels/
│   │   └── ChatViewModel.swift    # follow 流折叠 + 流式渲染
│   └── Views/
│       ├── SetupView.swift        # 配对 / 设置
│       ├── SessionListView.swift  # 会话列表
│       └── ChatView.swift         # 聊天界面
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
