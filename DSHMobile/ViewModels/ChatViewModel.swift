// ============================================================================
//  ChatViewModel.swift — 聊天会话的视图模型
//  ----------------------------------------------------------------------------
//  职责：
//    · 维护会话的持久 follow 流（WebSocket mux，endpoint session/follow），
//      断线指数退避自动重连，用 cursor 续传避免重复。
//    · 把 durable 事件（user/message、assistant/message、session/title …）折叠成
//      聊天消息列表。
//    · 把 assistant-stream 流帧（start/chunk/end）渲染成流式消息：
//      chunk.index 是 0-based 稠密块索引，按 attemptId 分桶；outcome.committed
//      携带最终 seq，用于与随后的 assistant/message 事件对齐（替换为完整内容）。
//    · 发送消息（session.prompt）、取消（session.cancel）。
// ============================================================================
import ActivityKit
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    enum ConnState: Equatable {
        case idle, connecting, connected, reconnecting, offline(String)
        var label: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "连接中…"
            case .connected: return "已连接"
            case .reconnecting: return "重连中…"
            case .offline(let msg): return msg
            }
        }
    }

    // MARK: - 状态
    let sessionId: String
    let settings: AppSettings

    @Published var messages: [ChatMessage] = []
    @Published var connState: ConnState = .idle
    @Published var isStreaming = false
    @Published var errorMessage: String?
    @Published var title: String?
    @Published var canSend = true

    // MARK: - 私有
    private var api: APIClient
    private var streamClient: StreamClient?
    private var followTask: Task<Void, Never>?
    private var cursor = 0
    private var hasLoadedInitial = false
    /// 初始快照是否已回放完毕：快照里的历史事件不触发通知 / 实时活动，
    /// 只有其后到达的 live 事件才需要用户处理。
    private var didApplyInitialSnapshot = false
    private var backoff: UInt64 = 500_000_000          // 0.5s 起步，翻倍到 8s
    private var streamingIndexByAttempt: [String: Int] = [:]
    /// 用户主动取消本轮任务（用于区分"用户取消"与"任务失败"）
    private var userCancelled = false
    /// 本轮开始时刻的 seq 边界（用于 turn/end 判定本轮产生的消息）
    private var turnStartSeq = 0
    /// 当前正在执行的步骤（工具调用 / 思考 / 等待授权），供灵动岛长按展示
    private var currentStep: String = ""

    init(sessionId: String, settings: AppSettings? = nil) {
        self.sessionId = sessionId
        // AppSettings.shared 是 MainActor 隔离的；在 init 体内访问（init 本身 MainActor）
        self.settings = settings ?? AppSettings.shared
        self.api = APIClient(settings: self.settings)
    }

    // MARK: - 生命周期

    func start() {
        guard followTask == nil else { return }
        followTask = Task { [weak self] in
            await self?.runFollowLoop()
        }
    }

    func stop() {
        followTask?.cancel()
        followTask = nil
        streamClient?.close()
        streamClient = nil
    }

    // MARK: - follow 主循环（自动重连）

    private func runFollowLoop() async {
        while !Task.isCancelled {
            // 关闭上一轮残留的连接（旧 client 被替换后无法再 close）
            streamClient?.close()
            streamClient = nil
            connState = .connecting
            let client = StreamClient(settings: settings)
            self.streamClient = client
            do {
                try await client.connect()
                connState = .connected
                // session/follow 的请求体（typert gateway：args 内层字段名=服务端参数名）
                let request: [String: Any] = [
                    "address": ["kind": "session", "sessionId": sessionId],
                    "cursor": cursor,
                    "maxMessages": 50,
                    "assistantStream": true,
                ]
                let payload: [String: Any] = ["args": ["request": request]]
                try await client.openStream(endpoint: "session/follow", payload: payload) { [weak self] frame in
                    self?.handleStreamFrame(frame)
                }
                // 正常 end：流被服务端关闭 → 重连
                connState = .reconnecting
            } catch let error as StreamError {
                connState = .offline(error.localizedDescription)
                errorMessage = error.localizedDescription
            } catch {
                connState = .offline(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
            // 指数退避
            backoff = min(backoff * 2, 8_000_000_000)
            try? await Task.sleep(nanoseconds: backoff)
            if Task.isCancelled { break }
        }
    }

    /// 流帧入口（StreamClient 的 onFrame 回调，非主线程 → 跳到 MainActor）
    private nonisolated func handleStreamFrame(_ frame: StreamFrame) {
        Task { @MainActor [weak self] in
            self?.apply(frame)
        }
    }

    private func apply(_ frame: StreamFrame) {
        switch frame {
        case .item(let value):
            guard let obj = value.objectValue else { return }
            switch obj["type"]?.stringValue {
            case "snapshot":
                applySnapshot(obj)
            case "event":
                if let evtValue = obj["event"] {
                    if let evt = try? decode(evtValue, as: SessionEvent.self) {
                        fold(event: evt)
                    }
                }
            case "assistant-stream":
                if let frameValue = obj["frame"] {
                    if let f = try? decode(frameValue, as: AssistantStreamFrame.self) {
                        applyAssistantFrame(f)
                    }
                }
            default:
                break
            }
        case .end:
            // 服务端关闭本流（receive 循环退出后会走到重连逻辑）
            break
        case .error(let name, let message, let code):
            errorMessage = "\(code ?? "stream")：\(message ?? name ?? "未知错误")"
        }
    }

    // MARK: - 快照

    private func applySnapshot(_ obj: [String: AnyCodable]) {
        do {
            let snap: FollowSnapshot = try decode(.object(obj), as: FollowSnapshot.self)
            let records = snap.records ?? []
            if !hasLoadedInitial {
                hasLoadedInitial = true
                messages.removeAll()
                for rec in records {
                    fold(event: rec.event)
                }
                // 初始快照回放完毕：之后的 fold 事件才是 live 事件
                didApplyInitialSnapshot = true
            } else {
                for rec in records {
                    fold(event: rec.event)
                }
            }
            cursor = max(cursor, snap.cursor)
        } catch {
            errorMessage = "快照解析失败：\(error.localizedDescription)"
        }
    }

    // MARK: - durable 事件折叠

    private func fold(event: SessionEvent) {
        cursor = max(cursor, event.seq)
        switch event.type {
        case "user/message":
            let blocks = contentBlocks(from: event.data)
            let msg = ChatMessage.make(id: "evt-\(event.seq)", seq: event.seq, role: .user, blocks: blocks, time: event.time)
            messages.append(msg)

        case "assistant/message":
            let blocks = contentBlocks(from: event.data)
            // 若存在同 seq 的流式消息（outcome 已提交 seq）→ 替换为完整内容
            if let idx = messages.firstIndex(where: { $0.seq == event.seq && $0.role == .assistant }) {
                let old = messages[idx]
                messages[idx] = ChatMessage.make(
                    id: old.id, seq: event.seq, role: .assistant, blocks: blocks,
                    time: event.time, isStreaming: false, attemptId: old.attemptId
                )
            } else {
                let msg = ChatMessage.make(id: "evt-\(event.seq)", seq: event.seq, role: .assistant, blocks: blocks, time: event.time)
                messages.append(msg)
            }
            isStreaming = false
            canSend = true

        case "session/title":
            if let t = event.data?.objectValue?["title"]?.stringValue, !t.isEmpty {
                title = t
            }

        case "turn/start":
            isStreaming = true
            canSend = false
            // 新一轮：重置取消标记，记录本轮消息边界
            userCancelled = false
            turnStartSeq = cursor
            // 初始快照回放的历史回合不启动实时活动 / 不通知
            if didApplyInitialSnapshot {
                beginLiveActivity()
            }
            // 启动本身不是"需要用户处理"的内容 → 不再发送"任务已启动"通知，
            // 进度交给灵动岛 / 锁屏实时活动展示。

        case "turn/end":
            isStreaming = false
            canSend = true
            if didApplyInitialSnapshot {
                // 读取权威的回合结束原因（data.reason.kind）：
                //   completed / blocked / aborted / error / max-tokens
                let reasonKind = event.data?.objectValue?["reason"]?.objectValue?["kind"]?.stringValue
                settleTurnEnd(reasonKind: reasonKind)
            }

        case "tool/call":
            // 工具开始执行：在灵动岛 / 锁屏展示当前步骤
            if let name = event.data?.objectValue?["name"]?.stringValue {
                currentStep = Self.stepLabel(for: name)
                let args = event.data?.objectValue?["arguments"]?.stringValue ?? ""
                let argDetail = Self.stepDetail(for: name, arguments: args)
                updateLiveActivityStep(detail: argDetail)
            }

        case "tool/result":
            // 工具执行完成 → 回到"处理中"；下一步事件会覆盖
            if !currentStep.isEmpty {
                currentStep = ""
                updateLiveActivityStep(detail: nil)
            }

        case "assistant/attempt":
            // 模型开始生成（思考 / 起草）
            currentStep = "思考中…"
            updateLiveActivityStep(detail: nil)

        case "step/start":
            // 新一轮 step 开始：若上一轮遗留"思考中"等标签，重置为通用状态
            if currentStep == "思考中…" {
                currentStep = ""
            }

        case "approval/asked":
            currentStep = "等待授权"
            updateLiveActivityStep(detail: nil)

        default:
            break
        }
    }

    /// 从 user/message 或 assistant/message 的 data 提取 content 块
    private func contentBlocks(from data: AnyCodable?) -> [ChatMessage.Block] {
        guard let obj = data?.objectValue else { return [] }
        // assistant/message 形状：{message:{role,content}}；user/message：{role,content}
        let content: [AnyCodable]? = obj["message"]?.objectValue?["content"]?.arrayValue
            ?? obj["content"]?.arrayValue
        guard let content else { return [] }
        return content.compactMap { c -> ChatMessage.Block? in
            guard let b = c.objectValue else { return nil }
            switch b["type"]?.stringValue {
            case "text":
                return .text(b["text"]?.stringValue ?? "")
            case "reasoning":
                return .reasoning(b["text"]?.stringValue ?? "")
            case "tool-call":
                return .toolCall(
                    id: b["id"]?.stringValue ?? "",
                    name: b["name"]?.stringValue ?? "",
                    arguments: b["arguments"]?.stringValue ?? ""
                )
            default:
                return .other
            }
        }
    }

    // MARK: - assistant-stream 流帧

    private func applyAssistantFrame(_ frame: AssistantStreamFrame) {
        if frame.isStart {
            let attemptId = frame.attemptId ?? UUID().uuidString
            let msg = ChatMessage.make(
                id: "stream-\(attemptId)", seq: 0, role: .assistant, blocks: [],
                time: frame.time ?? 0, isStreaming: true, attemptId: attemptId
            )
            messages.append(msg)
            streamingIndexByAttempt[attemptId] = messages.count - 1
            isStreaming = true
            canSend = false

        } else if frame.isChunk {
            guard let attemptId = frame.attemptId,
                  let idx = streamingIndexByAttempt[attemptId],
                  messages.indices.contains(idx) else { return }
            guard let chunk = frame.chunk else { return }
            let index = chunk.index ?? 0
            if chunk.isBlockStart {
                messages[idx].ensureBlock(at: index, type: chunk.blockType ?? "text")
            } else if chunk.isTextDelta, let text = chunk.text {
                messages[idx].appendText(text, at: index)
                updateLiveActivityProgress()
            } else if chunk.isReasoningDelta, let text = chunk.text {
                messages[idx].appendReasoning(text, at: index)
                updateLiveActivityProgress()
            } else if chunk.isToolCallDelta {
                messages[idx].appendToolCall(id: chunk.id, name: chunk.name, argumentsDelta: chunk.argumentsDelta ?? "", at: index)
            }

        } else if frame.isEnd {
            guard let attemptId = frame.attemptId,
                  let idx = streamingIndexByAttempt[attemptId],
                  messages.indices.contains(idx) else { return }
            let outcome = frame.outcome?.objectValue
            let kind = outcome?["kind"]?.stringValue
            if kind == "committed", let seq = outcome?["seq"]?.numberValue {
                messages[idx].seq = Int(seq)
                messages[idx].isStreaming = false
                // 等待随后的 assistant/message 事件替换为完整内容；
                // 完成判定统一交给 turn/end 的 settleTurnEnd()。
            } else {
                // abandoned → 移除占位
                messages.remove(at: idx)
                settleAbandoned()
            }
            streamingIndexByAttempt[attemptId] = nil
            // 若没有其他在途流，恢复发送
            if streamingIndexByAttempt.isEmpty {
                isStreaming = false
                canSend = true
            }
        }
    }

    // MARK: - 发送 / 取消

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        canSend = false
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.api.prompt(sessionId: self.sessionId, text: trimmed)
            } catch {
                self.errorMessage = "发送失败：\(error.localizedDescription)"
                self.canSend = true
            }
        }
    }

    func cancel() {
        userCancelled = true
        finishLiveActivity(status: "已取消", detail: "任务已取消", progress: 1.0)
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.api.cancelSession(sessionId: self.sessionId)
            } catch {
                self.errorMessage = "取消失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 通知 / 实时活动

    /// 流式字符累计（用于实时活动的字符计数与进度估算）
    private var streamedChars: Int = 0

    /// 当前实时活动实例
    private var liveActivity: Activity<TaskProgressAttributes>?

    /// turn/start：启动实时活动
    private func beginLiveActivity() {
        guard settings.liveActivitiesEnabled else { return }
        streamedChars = 0
        liveActivity = ActivityManager.shared.start(sessionId: sessionId, sessionTitle: title ?? "DSH 会话")
    }

    // MARK: - 回合结算（通知只围绕"需要用户处理的内容"）

    /// turn/end：统一结算本轮。
    /// reasonKind 是服务端的权威回合结束原因：
    ///   completed  → 正常完成；max-tokens → 达上限部分完成；
    ///   blocked    → 等待用户输入（需要回复）；
    ///   aborted    → 中断（reason 里 user=用户取消）；
    ///   error      → 运行失败。
    private func settleTurnEnd(reasonKind: String?) {
        switch reasonKind {
        case "error":
            finishLiveActivity(status: "已失败", detail: "任务运行出错", progress: 1.0)
            notifyIfBackgrounded(title: "任务失败", body: "\(title ?? "会话") 的任务运行出错，请查看对话。")
            return
        case "aborted":
            if userCancelled {
                // 用户主动取消 → 不打扰
                finishLiveActivity(status: "已取消", detail: "任务已取消", progress: 1.0)
            } else {
                finishLiveActivity(status: "已中断", detail: "任务被中断", progress: 1.0)
                notifyIfBackgrounded(title: "任务中断", body: "\(title ?? "会话") 的任务被中断，请查看对话。")
            }
            return
        case "blocked":
            // 等待用户输入 → 需要用户处理
            finishLiveActivity(status: "等待回复", detail: "等待你的输入", progress: 1.0)
            notifyIfBackgrounded(title: "对话需要你的回复", body: "\(title ?? "会话") 正在等待你的输入。")
            return
        default:
            // completed / max-tokens / 未知 → 走提问检测
            break
        }
        // 只检查本轮（seq > turnStartSeq）产生的已提交助手消息
        let candidate = messages.last { m in
            m.role == .assistant && !m.isStreaming && m.seq > turnStartSeq
        }
        if let last = candidate, messageAsksQuestion(last) {
            let preview = questionPreview(from: last)
            finishLiveActivity(status: "等待回复", detail: preview ?? "请查看对话", progress: 1.0)
            notifyIfBackgrounded(title: "对话需要你的回复", body: preview ?? "\(title ?? "会话") 中助手向你提出了问题。")
        } else {
            // 完成（或异常但无提问）→ 通知结果就绪
            let preview = candidate.flatMap { contentPreview(from: $0) }
            finishLiveActivity(status: "已完成", detail: "任务已完成")
            notifyIfBackgrounded(title: "任务已完成", body: preview ?? "\(title ?? "会话") 的回复已就绪。")
        }
    }

    /// assistant-stream abandoned：区分"用户取消"（不打扰）与"任务失败"（通知）
    private func settleAbandoned() {
        if userCancelled {
            // 用户主动取消 → 仅清灵动岛，不推送（用户自己发起的动作）
            finishLiveActivity(status: "已取消", detail: "任务已取消", progress: 1.0)
        } else {
            finishLiveActivity(status: "已失败", detail: "任务失败或中断", progress: 1.0)
            notifyIfBackgrounded(title: "任务失败", body: "\(title ?? "会话") 的任务失败或中断，请查看对话。")
        }
    }

    /// 判断一条助手消息是否在向用户提问（需要用户处理）
    private func messageAsksQuestion(_ m: ChatMessage) -> Bool {
        // 1) 显式提问工具调用
        if m.blocks.contains(where: {
            if case .toolCall(_, let name, _) = $0 { return name == "ask_user_question" }
            return false
        }) { return true }
        // 2) 文本形态的提问：以问号结尾，或含典型提问句式
        let text = m.blocks.map { $0.text }
            .filter { !$0.hasPrefix("[工具]") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.hasSuffix("?") || text.hasSuffix("？") { return true }
        let markers = ["请选择", "请确认", "请回复", "请回答", "需要你", "可以吗", "行吗", "要不要", "是否继续", "是否要", "请你", "你希望"]
        return markers.contains { text.contains($0) }
    }

    /// 提取提问预览：优先 ask_user_question 参数的 question 字段，否则取文本尾部
    private func questionPreview(from m: ChatMessage) -> String? {
        for block in m.blocks {
            if case .toolCall(_, let name, let args) = block, name == "ask_user_question" {
                if let data = args.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let q = obj["question"] as? String, !q.isEmpty {
                    return String(q.prefix(80))
                }
            }
        }
        let text = m.blocks.map { $0.text }
            .filter { !$0.hasPrefix("[工具]") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.suffix(80))
    }

    /// 常规内容预览（完成通知用）
    private func contentPreview(from m: ChatMessage) -> String? {
        let text = m.blocks.map { $0.text }
            .filter { !$0.hasPrefix("[工具]") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.suffix(60))
    }

    /// 流式增量：更新进度（估算）与状态文案
    private func updateLiveActivityProgress() {
        guard settings.liveActivitiesEnabled, let liveActivity else { return }
        // 汇总当前流式消息已收文本长度作为进度参考
        streamedChars = messages.reduce(0) { acc, m in
            acc + m.blocks.reduce(0) { $0 + ($1.text.count) }
        }
        // 无真实总量：用字符数做单调递增的饱和估算（约 2 万字符后逼近 92%）
        let estimated = min(0.92, 0.15 + Double(streamedChars) / 20_000.0 * 0.77)
        let detail = liveActivityPreview() ?? "正在生成回复…"
        ActivityManager.shared.update(
            progress: estimated,
            status: "运行中",
            detail: detail,
            chars: streamedChars,
            step: currentStep
        )
    }

    /// 步骤变化（工具执行 / 思考 / 等待授权）时刷新实时活动。
    /// - Parameter detail: 可选步骤详情（如正在运行的命令）；传 nil 时回落为流式预览。
    private func updateLiveActivityStep(detail: String?) {
        guard settings.liveActivitiesEnabled, liveActivity != nil else { return }
        streamedChars = messages.reduce(0) { acc, m in
            acc + m.blocks.reduce(0) { $0 + ($1.text.count) }
        }
        let estimated = min(0.92, 0.15 + Double(streamedChars) / 20_000.0 * 0.77)
        let text = detail ?? liveActivityPreview() ?? "正在生成回复…"
        ActivityManager.shared.update(
            progress: estimated,
            status: "运行中",
            detail: text,
            chars: streamedChars,
            step: currentStep
        )
    }

    /// 工具名 → 友好步骤标签（灵动岛长按展开 / 锁屏展示）
    private static func stepLabel(for name: String) -> String {
        switch name {
        case "bash", "shell", "exec", "command": return "运行命令"
        case "web_search", "search", "web_search_direct": return "搜索网页"
        case "read", "read_file": return "读取文件"
        case "write", "edit", "edit_file", "apply_patch": return "编辑文件"
        case "ask_user_question": return "向你提问"
        case "subagent", "subagent_fork": return "启动子代理"
        case "todo_write": return "更新任务清单"
        default: return "调用工具：\(name)"
        }
    }

    /// 提取步骤详情（如 bash 的具体命令 / 搜索词 / 文件路径）。
    /// 优先解析 arguments JSON 中的关键字段，失败则回落为原始参数串。
    private static func stepDetail(for name: String, arguments: String) -> String? {
        let fallback = {
            let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        }
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback()
        }
        switch name {
        case "bash", "shell", "exec", "command":
            if let cmd = obj["command"] as? String, !cmd.isEmpty {
                return String(cmd.prefix(40))
            }
        case "web_search", "search", "web_search_direct":
            if let q = obj["query"] as? String, !q.isEmpty {
                return String(q.prefix(40))
            }
            if let arr = obj["queries"] as? [String], let first = arr.first, !first.isEmpty {
                return String(first.prefix(40))
            }
        case "read", "read_file", "write", "edit", "edit_file":
            if let p = obj["path"] as? String, !p.isEmpty {
                return String(p.prefix(40))
            }
            if let p = obj["file_path"] as? String, !p.isEmpty {
                return String(p.prefix(40))
            }
        case "ask_user_question":
            if let q = obj["question"] as? String, !q.isEmpty {
                return String(q.prefix(40))
            }
        default:
            break
        }
        return fallback()
    }

    /// 结束实时活动（完成 / 取消 / 失败）
    private func finishLiveActivity(status: String, detail: String, progress: Double = 1.0) {
        guard settings.liveActivitiesEnabled, liveActivity != nil else { return }
        ActivityManager.shared.end(status: status, detail: detail, progress: progress)
        liveActivity = nil
    }

    /// 从流式消息提取一段预览文案
    private func liveActivityPreview() -> String? {
        for m in messages.reversed() {
            if m.isStreaming, let text = m.blocks.first(where: { $0.text.count > 0 })?.text {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : String(trimmed.prefix(60))
            }
        }
        return nil
    }

    /// 推送本地通知。
    /// 规则（会话级关注优先，再叠加全局开关）：
    ///   · 会话「静音」→ 一律不推；
    ///   · 会话「特别关注」→ 全局开启时必定推，即使 App 在前台；
    ///   · 否则（跟随全局）→ 仅全局开启且 App 不在前台时推。
    private func notifyIfBackgrounded(title: String, body: String) {
        guard settings.notificationsEnabled else { return }
        let level = settings.watchLevel(for: sessionId)
        guard level != .muted else { return }
        if level != .focused {
            let isForeground = UIApplication.shared.applicationState == .active
            guard !isForeground else { return }
        }
        Task { @MainActor in
            let status = await NotificationManager.shared.authorizationStatus()
            // 未决定时顺手请求一次授权；已拒绝就静默跳过（不再打扰）
            guard status == .authorized || status == .provisional else {
                if status == .notDetermined {
                    _ = await NotificationManager.shared.requestAuthorization()
                }
                return
            }
            NotificationManager.shared.notify(
                title: title,
                body: body,
                identifier: nil,
                userInfo: ["sessionId": sessionId]
            )
        }
    }

    // MARK: - 工具

    private func decode<T: Decodable>(_ value: AnyCodable, as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }
}
