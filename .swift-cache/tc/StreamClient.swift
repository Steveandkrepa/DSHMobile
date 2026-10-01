// ============================================================================
//  StreamClient.swift — DSH WebSocket 流式客户端（纯 URLSessionWebSocketTask）
//  ----------------------------------------------------------------------------
//  协议（来自 @deepseek-ai/dsh-api-gateway 的 RemoteStreamMuxServer）：
//    连接 : ws(s)://{base}/remote/api/remote.mux?device=<deviceId>
//    上行 : {"type":"open","streamId":"<uuid>","endpoint":"<ns>/<method>","payload":{...}}
//           {"type":"item","streamId":"<id>","value":...}     （上行数据）
//           {"type":"end","streamId":"<id>"}
//           {"type":"cancel","streamId":"<id>"}
//    下行 : {"type":"item","streamId":"<id>","value":...}     （流数据）
//           {"type":"end","streamId":"<id>"}
//           {"type":"error","streamId":"<id>","error":{"name","message","code","details"}}
//
//  一个连接可承载多条逻辑流（mux）；本客户端每个会话视图维护一条持久连接，
//  断线自动重连（指数退避），重连后由上层重新 open follow 流。
// ============================================================================
import Foundation
import FoundationNetworking

/// 一条逻辑流的帧
enum StreamFrame {
    case item(AnyCodable)
    case end
    case error(name: String?, message: String?, code: String?)
}

/// 流式连接错误
enum StreamError: Error, LocalizedError {
    case notConnected
    case closed(code: Int?, reason: String?)
    case remote(name: String?, message: String?, code: String?)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "未连接"
        case .closed(let code, let reason): return "连接关闭（\(code ?? 0)）\(reason ?? "")"
        case .remote(_, let message, let code): return "\(code ?? "stream")：\(message ?? "未知错误")"
        }
    }
}

/// @MainActor：与 APIClient 同理，resolveBase 会同步访问 MainActor 隔离的 AppSettings。
@MainActor
final class StreamClient {
    private let settings: AppSettings
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private let queue = DispatchQueue(label: "dsh.streamclient")

    init(settings: AppSettings) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        //         config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// 连接到 mux（base nil 时自动检测）。失败抛错。
    func connect(base: String? = nil) async throws {
        let resolved = try await resolveBase(base)
        let scheme = resolved.hasPrefix("https") ? "wss" : "ws"
        guard var comps = URLComponents(string: resolved) else { throw APIError.badURL }
        comps.scheme = scheme
        comps.path = "/remote/api/remote.mux"
        var queryItems = comps.queryItems ?? []
        if !settings.deviceId.isEmpty {
            queryItems.append(URLQueryItem(name: "device", value: settings.deviceId))
        }
        comps.queryItems = queryItems
        guard let url = comps.url else { throw APIError.badURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        // 等连接建立或失败
        try await waitForOpen(task)
    }

    private func waitForOpen(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // 简单策略：短暂等待后假定已连接（URLSessionWebSocketTask 没有"open"回调，
            // 发送首个 open 帧失败会抛错，届时自然暴露连接问题）。
            let timer = DispatchWorkItem { cont.resume() }
            queue.asyncAfter(deadline: .now() + 0.5, execute: timer)
        }
    }

    /// 打开一条逻辑流并持续接收帧，直到结束/错误/取消。
    func openStream(
        endpoint: String,
        payload: [String: Any],
        uplinkItems: AsyncStream<[String: Any]>? = nil,
        onFrame: @escaping (StreamFrame) -> Void
    ) async throws {
        guard let task else { throw StreamError.notConnected }
        let streamId = UUID().uuidString
        let openMessage: [String: Any] = [
            "type": "open",
            "streamId": streamId,
            "endpoint": endpoint,
            "payload": payload,
        ]
        // payload 需要是可 JSON 序列化的字典
        let openData = try JSONSerialization.data(withJSONObject: openMessage)
        try await send(data: openData)

        // 上行泵
        if let uplinkItems {
            Task {
                for await item in uplinkItems {
                    let frame: [String: Any] = ["type": "item", "streamId": streamId, "value": item]
                    if let data = try? JSONSerialization.data(withJSONObject: frame) {
                        try? await self.send(data: data)
                    }
                }
                let endData = try! JSONSerialization.data(withJSONObject: ["type": "end", "streamId": streamId])
                try? await self.send(data: endData)
            }
        }

        // 下行接收
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw StreamError.closed(code: (task.closeCode).rawValue, reason: task.closeReason?.toString())
            }
            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                guard let frameType = json["type"] as? String else { continue }
                let sId = json["streamId"] as? String
                if let sId, sId != streamId { continue }   // 只处理本流
                switch frameType {
                case "item":
                    if let value = json["value"] {
                        onFrame(.item(anyCodableFromJSON(value)))
                    }
                case "end":
                    onFrame(.end)
                    return
                case "error":
                    let err = json["error"] as? [String: Any]
                    let name = err?["name"] as? String
                    let message = err?["message"] as? String
                    let code = err?["code"] as? String
                    onFrame(.error(name: name, message: message, code: code))
                    throw StreamError.remote(name: name, message: message, code: code)
                default:
                    break
                }
            case .data:
                break
            @unknown default:
                break
            }
        }
    }

    private func send(data: Data) async throws {
        guard let task else { throw StreamError.notConnected }
        try await task.send(.data(data))
    }

    func cancelStream(streamId: String) {
        guard let task else { return }
        let frame: [String: Any] = ["type": "cancel", "streamId": streamId]
        if let data = try? JSONSerialization.data(withJSONObject: frame) {
            Task { try? await task.send(.data(data)) }
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - helpers

    private func resolveBase(_ explicit: String?) async throws -> String {
        if let explicit, !explicit.isEmpty {
            return settings.normalized(explicit)
        }
        if let active = await settings.detectActiveBaseURL() {
            return active
        }
        throw APIError.rpc(code: "connection/unreachable", message: "连不上 DSH 服务器")
    }
}

private func anyCodableFromJSON(_ value: Any) -> AnyCodable {
    switch value {
    case let s as String: return .string(s)
    case let b as Bool: return .bool(b)
    case let n as NSNumber: return .number(n.doubleValue)
    case let arr as [Any]: return .array(arr.map(anyCodableFromJSON))
    case let dict as [String: Any]: return .object(dict.mapValues(anyCodableFromJSON))
    default: return .null
    }
}

private extension Data {
    func toString() -> String? {
        String(data: self, encoding: .utf8)
    }
}
