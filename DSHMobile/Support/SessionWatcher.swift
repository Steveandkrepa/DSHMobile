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

@MainActor
final class SessionWatcher {
    static let shared = SessionWatcher()

    private var pollTask: Task<Void, Never>?
    private var engine: ChatViewModel?
    private var followedSessionId: String?
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
    }

    // MARK: - 轮询

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func pollOnce() async {
        guard settings.isPaired else { return }
        let api = APIClient(settings: settings)
        do {
            let sessions = try await api.listSessions()
            let running = sessions.filter { $0.running }
            let target = running.max { $0.updatedAt < $1.updatedAt }
            if let target {
                if target.sessionId != followedSessionId {
                    stopEngine()
                    let vm = ChatViewModel(sessionId: target.sessionId, settings: settings)
                    engine = vm
                    followedSessionId = target.sessionId
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
        engine?.stop()
        engine = nil
        followedSessionId = nil
    }
}
