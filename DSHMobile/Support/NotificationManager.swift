import Foundation
import UserNotifications

/// 通知点击 → 打开对应会话的路由。
/// 作为 UNUserNotificationCenter.delegate 常驻（在 App 入口注册），
/// 收到通知点击后把 sessionId 广播到 NotificationCenter，
/// 由 SessionListView 观察并跳转。
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let openSession = Notification.Name("dsh.openSession")

    static let shared = NotificationRouter()

    /// 前台收到通知时：照常显示横幅（配合"特别关注"强化提醒）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound, .badge]
    }

    /// 用户点击通知（或通知操作）→ 跳转会话
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let sessionId = userInfo["sessionId"] as? String else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: Self.openSession, object: nil, userInfo: ["sessionId": sessionId])
        }
    }
}

// 本地通知管理器。
//
// 免费签名（SideStore）无法使用 APNs 远程推送，因此"消息推送、及时通知"
// 用本地通知（UNUserNotificationCenter）实现：
//   - 任务开始 / 新回复到达 / 任务完成 时，App 在前台或后台都能立即弹通知
//   - 通知授权在设置页开关或首次进入会话时请求
//
// 线程模型：@MainActor 单例，方法均可在 async 上下文中安全调用。

@MainActor
final class NotificationManager {

    static let shared = NotificationManager()

    private init() {}

    /// 当前授权状态（.notDetermined / .denied / .authorized / .provisional / .ephemeral）
    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    /// 请求通知授权（.alert + .sound + .badge），返回是否已授权。
    @discardableResult
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// 立即发送一条本地通知（trigger = nil 表示马上送达）。
    /// userInfo 可带 sessionId，用于通知点击时跳转到对应会话。
    func notify(title: String, body: String, identifier: String? = nil, userInfo: [String: Any]? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "dsh-task"
        if let userInfo {
            content.userInfo = userInfo
        }

        let request = UNNotificationRequest(
            identifier: identifier ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
