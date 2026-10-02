// ============================================================================
//  DSHMobileApp.swift — 应用入口
//  ----------------------------------------------------------------------------
//  纯 SwiftUI 客户端：访问 DSH（DeepSeek Harness）Web 服务。
//    · 未配对 → SetupView（配置地址 + 配对令牌）
//    · 已配对 → SessionListView（会话列表 → 聊天）
// ============================================================================
import SwiftUI
import UserNotifications

@main
struct DSHMobileApp: App {
    @StateObject private var settings = AppSettings.shared

    init() {
        // 注册通知点击路由（常驻 delegate），通知点击 → 跳转对应会话
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

/// 根视图：按配对状态分流
struct RootView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Group {
            if settings.isPaired {
                SessionListView()
            } else {
                SetupView(mode: .initial)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: settings.isPaired)
    }
}
