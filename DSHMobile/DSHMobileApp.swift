// ============================================================================
//  DSHMobileApp.swift — 应用入口
//  ----------------------------------------------------------------------------
//  架构（原生主界面为主 + Web 组件兜底）：
//    · 未配对 → SetupView（配置地址 + 配对令牌 / 扫码配对）
//    · 已配对 → NativeMainView（原生 SwiftUI 主界面：会话列表 + 聊天）
//      会话列表/聊天按官方 DSH Web 功能对齐（一个功能都不能少），
//      复杂页面（官方完整 Web 设置）用 WKWebView 嵌入，App 设置用原生控制面板。
//
//  原生能力作为叠加层保留：
//    · SessionWatcher 后台跟随「正在运行」的会话 → 驱动灵动岛/锁屏实时活动
//      与本地通知（任务完成 / 失败 / 向你提问），并遵守会话级「特别关注」。
//    · 通知点击（NotificationRouter）把 App 带回前台，回到原生主界面。
// ============================================================================
import SwiftUI
import UserNotifications

@main
struct DSHMobileApp: App {
    @StateObject private var settings = AppSettings.shared

    init() {
        // 注册通知点击路由（常驻 delegate），让通知在 App 前台也能弹横幅
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)   // 深色为主（可后续加设置项）
                .tint(.purple)
        }
    }
}

/// 根视图：按配对状态分流（已配对 → 原生主界面）
struct RootView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Group {
            if settings.isPaired {
                NativeMainView()
            } else {
                SetupView(mode: .initial)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: settings.isPaired)
        .onAppear { syncWatcher() }
        .onChange(of: settings.isPaired) { _, paired in
            syncWatcher()
        }
    }

    /// 配对状态变化时启停后台会话跟随器
    private func syncWatcher() {
        if settings.isPaired {
            SessionWatcher.shared.start()
        } else {
            SessionWatcher.shared.stop()
        }
    }
}

/// 主界面：官方网页控制台承载对话流，原生只提供顶栏与底部输入条。
/// 见 WebChatShellView.swift（会话列表/对话流/仪表盘都用网页，避免与网页状态不一致）。
struct NativeMainView: View {
    var body: some View {
        WebChatShellView()
    }
}
