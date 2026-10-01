// ============================================================================
//  ChatViewModel.swift — 聊天会话的视图模型
//  ----------------------------------------------------------------------------
//  职责：
//    · 维护会话的持久 follow 流（WebSocket mux，endpoint session.follow），
//      断线指数退避自动重连，用 cursor 续传避免重复。
//    · 把 durable 事件（user/message、assistant/message、session/title …）折叠成
//      聊天消息列表。
//    · 把 assistant-stream 流帧（start/chunk/end）渲染成流式消息：
//      chunk.index 是 0-based 稠密块索引，按 attemptId 分桶；outcome.committed
//      携带最终 seq，用于与随后的 assistant/message 事件对齐（替换为完整内容）。
//    · 发送消息（session.prompt）、取消（session.cancel）。
// ============================================================================
import Foundation


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
    private var backoff: UInt64 = 500_000_000          // 0.5s 起步，翻倍到 8s
    private var streamingIndexByAttempt: [String: Int] = [:]

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
                let payload: [String: Any] = [
                    "address": ["kind": "session", "sessionId": sessionId],
                    "cursor": cursor,
                    "maxMessages": 50,
                    "assistantStream": true,
                ]
                try await client.openStream(endpoint: "session.follow", payload: payload) { [weak self] frame in
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

        case "turn/end":
            isStreaming = false
            canSend = true

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
            } else if chunk.isReasoningDelta, let text = chunk.text {
                messages[idx].appendReasoning(text, at: index)
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
                // 等待随后的 assistant/message 事件替换为完整内容
            } else {
                // abandoned → 移除占位
                messages.remove(at: idx)
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
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.api.cancelSession(sessionId: self.sessionId)
            } catch {
                self.errorMessage = "取消失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 工具

    private func decode<T: Decodable>(_ value: AnyCodable, as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }
}
