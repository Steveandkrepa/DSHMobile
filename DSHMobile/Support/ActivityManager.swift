import ActivityKit
import Foundation

// 实时活动管理器（ActivityKit）。
//
// 主 App 侧的统一入口：负责启动 / 更新 / 结束一个任务进度的实时活动，
// 该实时活动由 DSHMobileWidgets 扩展在灵动岛 / 锁屏 / 通知中心渲染。
//
// 免费签名（SideStore）无 APNs，因此所有更新都走本地
// `activity.update` / `activity.end`，不需要 pushType。
//
// 线程模型：@MainActor 单例，所有方法均在主线程调用（ChatViewModel 即主线程）。

@MainActor
final class ActivityManager {

    static let shared = ActivityManager()

    private init() {}

    /// 实时活动功能是否可用（用户在系统设置里开启"实时活动"开关且设备支持）。
    var isActivityEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 当前正在展示的实时活动（一个会话同时至多一个）。
    private(set) var current: Activity<TaskProgressAttributes>?

    /// 启动一个实时活动。
    /// - Returns: 启动成功返回 Activity 实例；设备不支持 / 用户关闭实时活动 / request 抛错时返回 nil。
    @discardableResult
    func start(sessionId: String, sessionTitle: String) -> Activity<TaskProgressAttributes>? {
        guard isActivityEnabled else { return nil }

        // 结束上一个未结束的活动，避免叠加
        endAll(status: "已切换", detail: "上一个任务已结束")

        let attributes = TaskProgressAttributes(
            sessionId: sessionId,
            sessionTitle: sessionTitle
        )
        let initialState = TaskProgressAttributes.ContentState(
            progress: 0.05,
            status: "运行中",
            detail: "正在准备…"
        )
        let content = ActivityContent(state: initialState, staleDate: nil)

        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            current = activity
            return activity
        } catch {
            current = nil
            return nil
        }
    }

    /// 更新实时活动状态（流式期间频繁调用）。
    func update(progress: Double, status: String, detail: String, chars: Int = 0, step: String = "") {
        guard let current else { return }
        let state = TaskProgressAttributes.ContentState(
            progress: progress,
            status: status,
            detail: detail,
            chars: chars,
            step: step
        )
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            await current.update(content)
        }
    }

    /// 结束当前实时活动（完成 / 取消 / 失败）。
    func end(status: String, detail: String, progress: Double = 1.0) {
        guard let current else { return }
        let state = TaskProgressAttributes.ContentState(
            progress: progress,
            status: status,
            detail: detail
        )
        let content = ActivityContent(state: state, staleDate: nil)
        let activity = current
        self.current = nil
        Task {
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }

    /// 结束所有实时活动（含非当前实例；用于设置里关闭实时活动时清理）。
    func endAll(status: String = "已结束", detail: String = "") {
        let running = Activity<TaskProgressAttributes>.activities
        for activity in running {
            let state = TaskProgressAttributes.ContentState(
                progress: 1.0,
                status: status,
                detail: detail
            )
            let content = ActivityContent(state: state, staleDate: nil)
            Task {
                await activity.end(content, dismissalPolicy: .immediate)
            }
        }
        current = nil
    }
}
