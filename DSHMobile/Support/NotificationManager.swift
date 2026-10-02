import Foundation
import UserNotifications

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
    func notify(title: String, body: String, identifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "dsh-task"

        let request = UNNotificationRequest(
            identifier: identifier ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
