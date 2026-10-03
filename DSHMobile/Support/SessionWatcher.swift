// ============================================================================
//  SessionWatcher.swift — 后台会话跟随器（原生叠加层引擎）
//  ----------------------------------------------------------------------------
//  主界面是 Web 壳，通知/灵动岛需要知道「现在有没有任务在跑、跑到哪一步」。
//  本 watcher 周期性轮询 session/list，找到「最近更新的正在运行」的会话，
//  交给 ChatViewModel（无头引擎）通过 session/follow 流实时跟随：
//    · turn/start → 启动灵动岛/锁屏实时活动（ActivityManager）
//    · turn/end   → 结束活动 + 按结果发本地通知（完成/失败/提问），遵守会话级
//                   「特别关注」（WatchLevel）
//  多个会话同时运行时只跟随最新的一个（灵动岛只保留一个）。
// ============================================================================
import Foundation
import Combine

@MainActor
final class SessionWatcher: ObservableObject {
    static let shared = SessionWatcher()

    /// 当前网页壳打开的会话摘要（用于原生顶栏标题/模型/模式/权限显示）
    @Published private(set) var activeSummary: SessionSummary?
    /// 当前打开的会话是否正在生成（原生输入条据此决定「发送」还是「插话/停止」）。
    /// 优先来自跟随流的 turn/start、turn/end（毫秒级准确）；没有跟随流时
    /// 回落到 session/list 的 running 字段（最多 5s 延迟）。
    @Published private(set) var activeIsRunning = false

    private var pollTask: Task<Void, Never>?
    private var engine: ChatViewModel?
    private var followedSessionId: String?
    /// 跟随流 isStreaming 的订阅（拿到精确的 turn/start、turn/end）
    private var engineCancellable: AnyCancellable?
    private let settings = AppSettings.shared

    private init() {}

    /// 开始轮询跟随（已配对时由 RootView 调用）
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// 停止轮询并断开跟随（取消配对时由 RootView 调用）
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        stopEngine()
        activeSummary = nil
        activeIsRunning = false
    }

    // MARK: - 轮询

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// 立即刷新一次（发送/停止后调用，让原生输入条状态尽快收敛）
    func refreshNow() {
        Task { await pollOnce() }
    }

    private func pollOnce() async {
        guard settings.isPaired else { return }
        let api = APIClient(settings: settings)
        do {
            let sessions = try await api.listSessions()
            // 当前打开的会话（含未运行的）：供原生顶栏显示标题/模型/模式/权限
            if let activeId = settings.activeWebSessionId {
                activeSummary = sessions.first { $0.sessionId == activeId }
            } else {
                activeSummary = nil
            }
            // 正在跟随目标会话时，以跟随流的 isStreaming 为准（turn/end 一到就是准确值）；
            // 否则用 session/list 的 running 字段兜底（最多 5s 延迟）。
            if let engine, followedSessionId == settings.activeWebSessionId {
                activeIsRunning = engine.isStreaming
            } else {
                activeIsRunning = activeSummary?.running ?? false
            }
            let running = sessions.filter { $0.running }
            // 优先跟随当前打开的会话（Web 壳 JS 检测回传）；否则跟随最近更新的运行中会话
            var target = running.first { $0.sessionId == settings.activeWebSessionId }
            if target == nil {
                target = running.max { $0.updatedAt < $1.updatedAt }
            }
            if let target {
                if target.sessionId != followedSessionId {
                    stopEngine()
                    let vm = ChatViewModel(sessionId: target.sessionId, settings: settings)
                    engine = vm
                    followedSessionId = target.sessionId
                    // 跟随流的 isStreaming 才是「回复是否结束」的权威信号
                    // （turn/start → true，turn/end → false），用它覆盖轮询的粗略值。
                    engineCancellable = vm.$isStreaming.sink { [weak self] streaming in
                        Task { @MainActor in
                            guard let self, self.followedSessionId == vm.sessionId,
                                  self.settings.activeWebSessionId == vm.sessionId else { return }
                            self.activeIsRunning = streaming
                        }
                    }
                    vm.start()
                }
            } else {
                stopEngine()
            }
        } catch {
            // 网络暂时不可用：静默等待下一轮重试
        }
    }

    private func stopEngine() {
        engineCancellable?.cancel()
        engineCancellable = nil
        engine?.stop()
        engine = nil
        followedSessionId = nil
    }
}
