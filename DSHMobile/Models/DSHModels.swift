// ============================================================================
//  DSHModels.swift — 与 DSH Web 接口对齐的数据模型（纯 Swift）
//  ----------------------------------------------------------------------------
//  这些结构体的字段名/形状与 DSH 的 Typert JSON-RPC 线上协议一一对应，
//  反编译自 @deepseek-ai/dsh-api-session-controller 与 @linxin666/dsh-remote-web-ui。
//
//  传输协议速览：
//    · HTTP RPC   ：POST {base}/remote/api/<endpoint>    （endpoint 用斜杠：session/list）
//                   请求  {"type":"client-request","rpcId","method":"<ns>/<method>","payload":{"args":{...}}}
//                   响应  {"type":"server-response","rpcId","result":{"ok","value"|"error"}}
//    · 流式 RPC   ：WebSocket {base}/remote/api/remote.mux?device=<id>
//                   上行  {"type":"open","streamId","endpoint","payload"}
//                   下行  {"type":"item","streamId","value"} / {"type":"end",...} / {"type":"error",...}
//    · 设备凭证   ：HTTP 头 x-dsh-remote-device:<deviceId>；WS 用 ?device=<deviceId>
// ============================================================================
import Foundation

// MARK: - 配对

/// POST /api/pair/accept 的请求体
struct PairAcceptRequest: Codable {
    let token: String
}

/// POST /api/pair/accept 的响应体（新设备配对成功后拿到 deviceId）
struct PairAcceptResponse: Codable {
    let ok: Bool
    let deviceId: String?
    let code: String?
}

// MARK: - HTTP RPC 信封

/// 客户端 → 服务端的 RPC 请求信封（typert gateway 格式）
struct RPCEnvelope: Encodable {
    let type: String = "client-request"
    let rpcId: String
    let method: String
    /// 内层必须是 {args: {...}}；args 字段名 = 服务端方法参数名（request/_request/空）
    let payload: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case type, rpcId, method, payload
    }
}

/// 服务端 → 客户端的 RPC 响应信封（成功或失败）
struct RPCResponseEnvelope: Decodable {
    let type: String?
    let rpcId: String?
    let result: RPCResult?
    let error: RPCErrorEnvelope?
}

struct RPCResult: Decodable {
    let ok: Bool
    let value: AnyCodable?
    let error: RPCErrorEnvelope?
}

struct RPCErrorEnvelope: Decodable {
    let name: String?
    let message: String?
    let code: String?
    let details: AnyCodable?
}

/// JSON 里"任意可 Codable 值"的透明包装
enum AnyCodable: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Double.self) { self = .number(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([AnyCodable].self) { self = .array(v); return }
        if let v = try? container.decode([String: AnyCodable].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable: 无法解码的值")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    // MARK: 便捷取值
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
    var objectValue: [String: AnyCodable]? {
        if case .object(let o) = self { return o }
        return nil
    }
    var arrayValue: [AnyCodable]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

// MARK: - 会话

/// session/list 的响应（items 包一层）
struct SessionListResponse: Decodable {
    let items: [SessionSummary]
}

/// session.list 返回的一条会话摘要
struct SessionSummary: Decodable, Identifiable {
    let sessionId: String
    let updatedAt: Double
    let agentAvailable: Bool
    let running: Bool
    let blank: Bool
    let cwd: String?
    let parentSessionId: String?
    let origin: String?
    let projections: AnyCodable?

    var id: String { sessionId }
}

// MARK: - 会话事件

/// session.follow / session.page 返回的记录（一条 durable 事件）
struct SessionEventRecord: Decodable {
    let type: String
    let event: SessionEvent
}

struct SessionEvent: Decodable {
    let type: String
    let seq: Int
    let time: Int
    let data: AnyCodable?
    let surfaceOp: String?
    let ignorable: Bool?
}

// MARK: - 消息渲染模型（由事件折叠而来）

/// 聊天里的一"条"消息（用户/助手）
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case system
    }

    /// 内容块
    enum Block: Equatable {
        case text(String)
        case reasoning(String)
        case toolCall(id: String, name: String, arguments: String)
        case file(name: String, bytes: Int64)
        case other

        var displayText: String? {
            switch self {
            case .text(let t): return t
            case .reasoning(let t): return t
            case .toolCall(_, let n, _): return "[工具] \(n)"
            case .file(let n, _): return "[文件] \(n)"
            case .other: return nil
            }
        }

        /// 纯文本内容（用于字符计数 / 预览）
        var text: String {
            switch self {
            case .text(let t), .reasoning(let t): return t
            case .toolCall(_, let n, _): return "[工具] \(n)"
            case .file(let n, _): return "[文件] \(n)"
            case .other: return ""
            }
        }
    }

    let id: String          // "evt-<seq>" 或 "stream-<attemptId>"
    var seq: Int
    let role: Role
    var blocks: [Block]
    let time: Int
    var isStreaming: Bool = false
    var attemptId: String? = nil   // 流式生成回合标识
    var streamedText: String = ""   // 流式增量拼接（保留字段）
    var pendingText: String = ""    // 完整文本（流式完成或从事件还原）

    var displayText: String {
        if isStreaming { return streamedText.isEmpty ? (pendingText.isEmpty ? "…" : pendingText) : streamedText }
        return pendingText
    }

    var summary: String {
        if !pendingText.isEmpty { return pendingText }
        return blocks.map { $0.displayText ?? "" }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: 流式块拼接

    /// 确保 index 处存在块；blockType 决定占位类型
    mutating func ensureBlock(at index: Int, type: String) {
        while blocks.count <= index { blocks.append(.other) }
        if case .other = blocks[index] {
            switch type {
            case "text": blocks[index] = .text("")
            case "reasoning": blocks[index] = .reasoning("")
            case "tool-call": blocks[index] = .toolCall(id: "", name: "", arguments: "")
            default: break
            }
        }
    }

    mutating func appendText(_ text: String, at index: Int) {
        ensureBlock(at: index, type: "text")
        if case .text(let existing) = blocks[index] {
            blocks[index] = .text(existing + text)
        }
        streamedText += text
    }

    mutating func appendReasoning(_ text: String, at index: Int) {
        ensureBlock(at: index, type: "reasoning")
        if case .reasoning(let existing) = blocks[index] {
            blocks[index] = .reasoning(existing + text)
        }
        streamedText += text
    }

    mutating func appendToolCall(id: String?, name: String?, argumentsDelta: String, at index: Int) {
        ensureBlock(at: index, type: "tool-call")
        if case .toolCall(let oldId, let oldName, let oldArgs) = blocks[index] {
            blocks[index] = .toolCall(
                id: id ?? oldId,
                name: name ?? oldName,
                arguments: oldArgs + argumentsDelta
            )
        }
    }

    /// 静态构造（工具函数，供折叠逻辑使用）
    static func make(
        id: String,
        seq: Int,
        role: Role,
        blocks: [Block],
        time: Int,
        isStreaming: Bool = false,
        attemptId: String? = nil
    ) -> ChatMessage {
        ChatMessage(id: id, seq: seq, role: role, blocks: blocks, time: time,
                    isStreaming: isStreaming, attemptId: attemptId)
    }
}

// MARK: - 流式 assistant-stream 帧

/// WebSocket mux 下行的流帧信封
enum StreamDownlinkFrame {
    case item(value: AnyCodable)
    case end
    case error(name: String?, message: String?, code: String?)
}

/// assistant-stream 帧（revision 单调递增）
struct AssistantStreamFrame: Decodable {
    let type: String
    let revision: Int
    let attemptId: String?
    let turn: Int?
    let step: Int?
    let startedAfterSeq: Int?
    let index: Int?
    let time: Int?
    let chunk: StreamChunk?
    let outcome: AnyCodable?

    /// 是否属于某个"新的生成回合"
    var isStart: Bool { type == "start" }
    var isEnd: Bool { type == "end" }
    var isChunk: Bool { type == "chunk" }
}

struct StreamChunk: Decodable {
    let type: String
    let index: Int?
    let text: String?
    let id: String?
    let name: String?
    let argumentsDelta: String?
    let blockType: String?
    let block: AnyCodable?
    let usage: AnyCodable?
    let reason: String?
    let replayState: AnyCodable?

    var isTextDelta: Bool { type == "text-delta" }
    var isReasoningDelta: Bool { type == "reasoning-delta" }
    var isToolCallDelta: Bool { type == "tool-call-delta" }
    var isBlockStart: Bool { type == "block-start" }
    var isBlockEnd: Bool { type == "block-end" }
    var isFinish: Bool { type == "finish" }
    var isUsage: Bool { type == "usage" }
}

// MARK: - follow 快照

struct FollowSnapshot: Decodable {
    let type: String
    let cursor: Int
    let records: [SessionEventRecord]?
    let hasMore: Bool?
    let projections: AnyCodable?
    let assistantStream: AnyCodable?
}

// MARK: - Agent 预设（模式）

/// agentPresets/list 的响应
struct AgentPresetRoster: Decodable {
    let presets: [AgentPresetRow]
}

/// 一个 Agent 预设（标准/创造/极简/PTC/梁神模式…）
struct AgentPresetRow: Decodable, Identifiable {
    let id: String
    let name: String?
    let description: String?
    let order: Int?
    let isDefault: Bool?
}

/// agentPresets/read 的响应
struct AgentPresetDocument: Decodable {
    let agentPreset: String
    let content: AnyCodable?
    let name: String?
    let description: String?
}

// MARK: - 模型目录

/// session/modelCatalog 的响应（类型化）
struct ModelCatalog: Decodable {
    let defaultModel: ModelSelection?
    let routableProviders: [String]?
    let groups: [ModelProviderGroup]
    let failures: [AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case defaultModel = "default"
        case routableProviders, groups, failures
    }
}

struct ModelSelection: Decodable, Equatable {
    let provider: String
    let model: String
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case provider, model, reasoningEffort
    }
}

struct ModelProviderGroup: Decodable, Identifiable {
    let id: String
    let name: String?
    let models: [ModelCatalogModel]
}

struct ModelCatalogModel: Decodable, Identifiable {
    let id: String
    let name: String?
    let description: String?
    let reasoning: ModelReasoning?
}

struct ModelReasoning: Decodable {
    let efforts: [ModelReasoningEffort]
    let defaultEffort: String?
}

struct ModelReasoningEffort: Decodable, Identifiable {
    let id: String
    let name: String?
    let description: String?
}

// MARK: - 权限预设

/// permissionPresets/catalog 的响应
struct PermissionCatalog: Decodable {
    let options: [PresetOption]
    let defaultOptions: [PresetOption]?
    let defaultPreset: String?
}

struct PresetOption: Decodable, Identifiable {
    let value: String
    let name: String?
    let description: String?

    var id: String { value }
}

// MARK: - 会话派生

/// session/fork 的响应
struct SessionForkValue: Decodable {
    let sessionId: String
}

// MARK: - 会话投影便利访问

extension SessionSummary {
    /// 投影里的标题（projections.values.title）
    var projectedTitle: String? {
        projections?.objectValue?["values"]?.objectValue?["title"]?.stringValue
    }

    /// 投影里的 token 用量（projections.values.tokenUsage.totals）
    var projectedTokenUsage: TokenTotals? {
        guard let values = projections?.objectValue?["values"]?.objectValue,
              let tu = values["tokenUsage"]?.objectValue,
              let totals = tu["totals"]?.objectValue else { return nil }
        return TokenTotals(
            uncachedInputTokens: totals["uncachedInputTokens"]?.numberValue ?? 0,
            outputTokens: totals["outputTokens"]?.numberValue ?? 0,
            cacheReadTokens: totals["cacheReadTokens"]?.numberValue ?? 0,
            cacheWriteTokens: totals["cacheWriteTokens"]?.numberValue ?? 0
        )
    }

    /// 投影里的上下文占用（projections.values.contextPressure）
    var projectedContextPressure: ContextPressureInfo? {
        guard let values = projections?.objectValue?["values"]?.objectValue,
              let cp = values["contextPressure"]?.objectValue else { return nil }
        return ContextPressureInfo(
            pressureTokens: cp["pressureTokens"]?.numberValue ?? 0,
            projectedTokens: cp["projectedTokens"]?.numberValue,
            contextWindow: cp["contextWindow"]?.numberValue
        )
    }

    /// 投影里的当前模型选择（projections.values.modelSelection.next ?? lastUsed）
    var projectedModelSelection: ModelSelection? {
        guard let values = projections?.objectValue?["values"]?.objectValue,
              let ms = values["modelSelection"]?.objectValue else { return nil }
        let selection = ms["next"] ?? ms["lastUsed"]
        guard let sel = selection?.objectValue,
              let provider = sel["provider"]?.stringValue,
              let model = sel["model"]?.stringValue else { return nil }
        return ModelSelection(provider: provider, model: model, reasoningEffort: sel["reasoningEffort"]?.stringValue)
    }

    /// 投影里的当前 Agent 预设 id（projections.values.agentPreset）
    var projectedAgentPreset: String? {
        projections?.objectValue?["values"]?.objectValue?["agentPreset"]?.stringValue
    }

    /// 投影里的权限（projections.values.permissions.currentValue）
    var projectedPermission: String? {
        projections?.objectValue?["values"]?.objectValue?["permissions"]?.objectValue?["currentValue"]?.stringValue
    }
}

/// token 用量（与 dsh-token-meter 的 wire view 对齐：四个累计桶）
struct TokenTotals: Equatable {
    let uncachedInputTokens: Double
    let outputTokens: Double
    let cacheReadTokens: Double
    let cacheWriteTokens: Double

    var total: Double { uncachedInputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

    /// 简短格式化（K/M）
    func short(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return String(format: "%.0f", value)
    }
}

/// 上下文占用信息
struct ContextPressureInfo: Equatable {
    let pressureTokens: Double
    let projectedTokens: Double?
    let contextWindow: Double?
}
