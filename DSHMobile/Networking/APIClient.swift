// ============================================================================
//  APIClient.swift — DSH HTTP JSON-RPC 客户端（纯 URLSession）
//  ----------------------------------------------------------------------------
//  协议（来自 @deepseek-ai/dsh-client-connection 的 rpcFetchHandler）：
//    POST {base}/remote/api/<endpoint>
//    Headers: content-type: application/json
//             x-dsh-remote-device: <deviceId>   （配对设备凭证）
//    Body   : {"rpcId":"<uuid>","method":"<endpoint>","payload":{...}}
//    成功   : {"type":"server-response","rpcId":"...","result":{"ok":true,"value":...}}
//    失败   : {"type":"server-response","rpcId":"...","result":{"ok":false,"error":{"name","message","code","details"}}}
//
//  本客户端所有业务调用走 /remote/api/* 镜像通道（与浏览器端配对设备一致），
//  设备凭证是"全权"凭证：除配对/更新/插件管理外都能用。
// ============================================================================
import Foundation

/// DSH RPC 调用错误
enum APIError: Error, LocalizedError {
    case badURL
    case transport(Error)
    case httpStatus(Int)
    case badEnvelope
    case rpc(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务器地址无效"
        case .transport(let e): return "网络错误：\(e.localizedDescription)"
        case .httpStatus(let code): return "HTTP \(code)"
        case .badEnvelope: return "响应格式无法解析"
        case .rpc(let code, let message): return "\(code)：\(message)"
        }
    }
}

/// @MainActor：AppSettings 是 MainActor 隔离的（@Published），
/// 统一在主线程执行网络调度，避免跨隔离的同步调用。
@MainActor
struct APIClient {
    let settings: AppSettings

    // MARK: - 底层 RPC

    /// 发起一次 HTTP RPC；`base` 为 nil 时自动检测。
    func call<T: Decodable>(
        _ endpoint: String,
        payload: [String: Any],
        base: String? = nil,
        as type: T.Type
    ) async throws -> T {
        let resolvedBase = try await resolveBase(base)
        guard let url = URL(string: "\(resolvedBase)/remote/api/\(endpoint)") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !settings.deviceId.isEmpty {
            request.setValue(settings.deviceId, forHTTPHeaderField: "x-dsh-remote-device")
        }

        let rpcId = UUID().uuidString
        let body = RPCEnvelope(rpcId: rpcId, method: endpoint, payload: payload.mapValues(AnyCodable.from))
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw APIError.transport(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.httpStatus(http.statusCode)
        }

        return try decodeResult(data, as: type)
    }

    /// 解码 RPC 响应信封，取出 result.value 并解码成 T。
    private func decodeResult<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let envelope: RPCResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(RPCResponseEnvelope.self, from: data)
        } catch {
            throw APIError.badEnvelope
        }
        if let result = envelope.result {
            if result.ok {
                if let value = result.value {
                    do {
                        return try decodeAny(value, as: type)
                    } catch {
                        throw APIError.badEnvelope
                    }
                }
                // ok 但没有 value：要求 T 是"空响应"可解码类型
                if let empty = try? JSONDecoder().decode(type, from: "{}".data(using: .utf8)!) {
                    return empty
                }
                throw APIError.badEnvelope
            } else if let err = result.error {
                throw APIError.rpc(code: err.code ?? "unknown", message: err.message ?? "未知错误")
            } else {
                throw APIError.badEnvelope
            }
        }
        if let err = envelope.error {
            throw APIError.rpc(code: err.code ?? "unknown", message: err.message ?? "未知错误")
        }
        throw APIError.badEnvelope
    }

    /// 把 AnyCodable 转成任意 Decodable（JSON 中间表示再解码）
    private func decodeAny<T: Decodable>(_ value: AnyCodable, as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - 业务方法

    /// 会话列表
    func listSessions() async throws -> [SessionSummary] {
        let items: [SessionSummary] = try await call("session.list", payload: [:], as: [SessionSummary].self)
        return items
    }

    /// 新建会话
    struct CreateSessionResult: Decodable {
        let sessionId: String
        let agentPreset: String?
    }
    func createSession(agentPreset: String? = nil) async throws -> CreateSessionResult {
        var payload: [String: Any] = [:]
        if let agentPreset { payload["agentPreset"] = agentPreset }
        return try await call("session.create", payload: payload, as: CreateSessionResult.self)
    }

    /// 发送消息（followup 模式）
    struct PromptResult: Decodable {
        let accepted: Bool
    }
    func prompt(sessionId: String, text: String, requestId: String = UUID().uuidString) async throws -> PromptResult {
        let content: [[String: Any]] = [["type": "text", "text": text]]
        let payload: [String: Any] = [
            "sessionId": sessionId,
            "content": content,
            "requestId": requestId,
        ]
        return try await call("session.prompt", payload: payload, as: PromptResult.self)
    }

    /// 取消当前回合
    struct CancelResult: Decodable {
        let accepted: Bool
    }
    func cancelSession(sessionId: String) async throws -> CancelResult {
        let payload: [String: Any] = ["sessionId": sessionId]
        return try await call("session.cancel", payload: payload, as: CancelResult.self)
    }

    /// 重命名会话
    struct RenameResult: Decodable {
        let title: String
        let seq: Int
    }
    func renameSession(sessionId: String, title: String) async throws -> RenameResult {
        let payload: [String: Any] = ["sessionId": sessionId, "title": title]
        return try await call("session.rename", payload: payload, as: RenameResult.self)
    }

    /// 配对：用一次性 token 换取 deviceId
    func pairAccept(token: String, base: String) async throws -> PairAcceptResponse {
        guard let url = URL(string: "\(base)/api/pair/accept") else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(PairAcceptRequest(token: token))
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(PairAcceptResponse.self, from: data)
    }

    // MARK: - base 解析

    private func resolveBase(_ explicit: String?) async throws -> String {
        if let explicit, !explicit.isEmpty {
            return settings.normalized(explicit)
        }
        if let active = await settings.detectActiveBaseURL() {
            return active
        }
        throw APIError.rpc(code: "connection/unreachable", message: "连不上 DSH 服务器（局域网与公网都不可达）")
    }
}

// MARK: - AnyCodable 便利构造

extension AnyCodable {
    static func from(_ value: Any) -> AnyCodable {
        switch value {
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as [String: Any]:
            return .object(v.mapValues(AnyCodable.from))
        case let v as [Any]:
            return .array(v.map(AnyCodable.from))
        default: return .null
        }
    }
}
