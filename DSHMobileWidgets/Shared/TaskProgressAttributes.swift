import ActivityKit
import Foundation

// 任务进度实时活动的共享类型。
//
// 重要：此文件**同时编译进主 App target 与 Widget 扩展 target**
//（见 project.yml —— 两个 target 的 sources 都包含 DSHMobileWidgets/Shared）。
// ActivityKit 依靠属性类型在 App 与 Widget 之间的同名匹配来关联实时活动，
// 因此两个模块里的类型声明必须完全一致（字段名、类型、Codable 形状）。
//
// 使用场景：
//  - 主 App 侧：ChatViewModel 在任务 turn/start 时启动实时活动，
//    流式期间用 ContentState 更新进度，turn/end 或取消时结束。
//  - Widget 侧：TaskProgressLiveActivity 的 ActivityConfiguration 渲染
//    灵动岛（compact / expanded / minimal）与锁屏/横幅。

public struct TaskProgressAttributes: ActivityAttributes {

    /// 实时活动的可变状态 —— 每次 update 都会重建一个实例推送过去。
    public struct ContentState: Codable, Hashable {

        /// 进度 0.0 … 1.0（流式期间为估计值，完成/取消为 1.0）
        public var progress: Double

        /// 状态文案：运行中 / 已完成 / 已取消 / 已暂停
        public var status: String

        /// 当前阶段说明（如"正在生成回复…"、流式文本预览）
        public var detail: String

        /// 已流式收到的字符数（用于细粒度展示）
        public var chars: Int

        /// 当前步骤标签（如"运行命令""思考中…""调用工具：xxx"），
        /// 供灵动岛长按展开 / 锁屏时展示当前执行到哪一步。
        public var step: String

        /// 会话累计 token 消耗（如"输出 3.2K · 总计 12.4K"），
        /// 来自服务端 tokenUsage 投影（uncachedInput + cacheRead + cacheWrite + output）。
        public var tokens: String

        public init(progress: Double, status: String, detail: String, chars: Int = 0, step: String = "", tokens: String = "") {
            self.progress = progress
            self.status = status
            self.detail = detail
            self.chars = chars
            self.step = step
            self.tokens = tokens
        }
    }

    /// 每个实时活动的固定标识：所属会话 + 会话标题
    public var sessionId: String
    public var sessionTitle: String

    public init(sessionId: String, sessionTitle: String) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
    }
}
