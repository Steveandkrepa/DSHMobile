// ============================================================================
//  AppSettings.swift — 连接配置（服务器地址 + 设备凭证）
//  ----------------------------------------------------------------------------
//  连接模型：
//    · 用户配置「局域网地址」（http://192.168.x.x:PORT）与「公网地址」
//      （https://<id>.dsh-market.com，即 pairing relay / tunnel 域名）。
//    · 客户端自动检测：先试局域网（延迟低），失败/超时则回落公网。
//    · 设备凭证 = 配对时服务端签发的 deviceId，
//      HTTP 请求作为 x-dsh-remote-device 头、WebSocket 作为 ?device= 查询参数。
// ============================================================================
import Foundation
import SwiftUI

/// GET /api/pair/status 响应（含服务器局域网/公网地址信息）
struct PairStatusInfo: Codable {
    let ok: Bool?
    let lanAvailable: Bool?
    let lanAddresses: [String]?
    let publicUrl: String?
    let posture: Posture?

    struct Posture: Codable {
        let hosts: [Host]?
    }
    struct Host: Codable {
        let host: String?
        let exposed: Bool?
    }
}

@MainActor
final class AppSettings: ObservableObject {
    // MARK: - 持久化键
    private enum Key {
        static let lanURL = "settings.lanURL"
        static let publicURL = "settings.publicURL"
        static let deviceId = "settings.deviceId"
        static let paired = "settings.paired"
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let liveActivitiesEnabled = "settings.liveActivitiesEnabled"
    }

    // MARK: - 状态
    @Published var lanURL: String = UserDefaults.standard.string(forKey: Key.lanURL) ?? ""
    @Published var publicURL: String = UserDefaults.standard.string(forKey: Key.publicURL) ?? ""
    @Published var deviceId: String = UserDefaults.standard.string(forKey: Key.deviceId) ?? ""
    @Published var isPaired: Bool = UserDefaults.standard.bool(forKey: Key.paired)

    /// 消息推送 / 任务提醒（本地通知）
    @Published var notificationsEnabled: Bool = {
        if UserDefaults.standard.object(forKey: Key.notificationsEnabled) == nil {
            return true // 默认开启
        }
        return UserDefaults.standard.bool(forKey: Key.notificationsEnabled)
    }()

    /// 灵动岛 / 实时活动
    @Published var liveActivitiesEnabled: Bool = {
        if UserDefaults.standard.object(forKey: Key.liveActivitiesEnabled) == nil {
            return true // 默认开启
        }
        return UserDefaults.standard.bool(forKey: Key.liveActivitiesEnabled)
    }()

    /// 当前生效的 base URL（自动检测后的结果）
    @Published private(set) var activeBaseURL: String?
    /// 当前连接通道：lan / public
    @Published private(set) var activeChannel: Channel = .unknown

    enum Channel: String {
        case lan, publicNet, unknown
        var label: String {
            switch self {
            case .lan: return "局域网直连"
            case .publicNet: return "公网中转"
            case .unknown: return "未连接"
            }
        }
    }

    private let defaults = UserDefaults.standard

    /// 全局共享实例（App 入口注入 environmentObject，视图内也可直接使用）
    static let shared = AppSettings()

    init() {}

    // MARK: - 存取
    func save(lanURL: String, publicURL: String, deviceId: String) {
        self.lanURL = lanURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.publicURL = publicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(self.lanURL, forKey: Key.lanURL)
        defaults.set(self.publicURL, forKey: Key.publicURL)
        defaults.set(self.deviceId, forKey: Key.deviceId)
        isPaired = !self.deviceId.isEmpty && (!self.lanURL.isEmpty || !self.publicURL.isEmpty)
        defaults.set(isPaired, forKey: Key.paired)
        activeBaseURL = nil
        activeChannel = .unknown
    }

    func markUnpaired() {
        isPaired = false
        defaults.set(false, forKey: Key.paired)
        activeBaseURL = nil
        activeChannel = .unknown
    }

    // MARK: - 通知 / 实时活动开关
    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        defaults.set(enabled, forKey: Key.notificationsEnabled)
    }

    func setLiveActivitiesEnabled(_ enabled: Bool) {
        liveActivitiesEnabled = enabled
        defaults.set(enabled, forKey: Key.liveActivitiesEnabled)
        if !enabled {
            // 关闭时立即结束所有在途实时活动
            ActivityManager.shared.endAll(status: "已关闭", detail: "实时活动已由设置关闭")
        }
    }

    // MARK: - URL 规范化
    /// 去掉尾斜杠
    func normalized(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: - 自动检测（局域网优先，失败回落公网）
    /// 返回当前可用的 base URL；nil 表示都不通。
    func detectActiveBaseURL() async -> String? {
        // 已探测过且仍有效 → 直接复用
        if let cached = activeBaseURL { return cached }

        let candidates: [(String, Channel)] = {
            var list: [(String, Channel)] = []
            if !lanURL.isEmpty { list.append((normalized(lanURL), .lan)) }
            if !publicURL.isEmpty { list.append((normalized(publicURL), .publicNet)) }
            return list
        }()

        for (base, channel) in candidates {
            if await probe(base) {
                activeBaseURL = base
                activeChannel = channel
                return base
            }
        }
        activeBaseURL = nil
        activeChannel = .unknown
        return nil
    }

    /// 轻量探测：GET /api/pair/status（任意 DSH Web 都有这个端点）
    private func probe(_ base: String) async -> Bool {
        guard let url = URL(string: "\(base)/api/pair/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                // 401/403 也算"服务器在"，只是需要凭证；配对/未配对状态都说明可达。
                return (200...499).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - 服务器信息（配对成功后自动补全双地址）

    /// 拉取服务器配对状态（含局域网/公网地址信息）；失败返回 nil。
    func fetchPairStatus(base: String) async -> PairStatusInfo? {
        guard let url = URL(string: "\(normalized(base))/api/pair/status") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                return try? JSONDecoder().decode(PairStatusInfo.self, from: data)
            }
            return nil
        } catch {
            return nil
        }
    }

    /// 从服务器信息推导局域网 URL（http://<ip>:<port>）：
    /// 优先取 posture.hosts 里以局域网 IP 开头的完整 host（如 "192.168.1.100:3080"），
    /// 否则用局域网 IP + 配对 base 的端口，最后兜底 3080。
    func deriveLanURL(from info: PairStatusInfo, fallbackPort: Int?) -> String? {
        guard let lanIP = info.lanAddresses?.first, !lanIP.isEmpty else { return nil }
        if let hosts = info.posture?.hosts {
            for h in hosts {
                guard let host = h.host else { continue }
                // 形如 "192.168.1.100:3080"（或裸 IP）
                if host == lanIP || host.hasPrefix(lanIP + ":") {
                    return "http://" + host
                }
            }
        }
        let port = fallbackPort ?? 3080
        return "http://\(lanIP):\(port)"
    }

    /// 配对 API 的 base（配对端点必须走根路径 /api/pair/*，不经过 /remote 镜像）
    func pairingBase() -> String? {
        if !publicURL.isEmpty { return normalized(publicURL) }
        if !lanURL.isEmpty { return normalized(lanURL) }
        return nil
    }

    /// 带临时表单值的配对 base（供 SetupView 使用）
    func pairingBase(for lan: String, publicURL pub: String) -> String? {
        let lan = normalized(lan), pub = normalized(pub)
        if !pub.isEmpty { return pub }
        if !lan.isEmpty { return lan }
        return nil
    }

    // MARK: - 会话级通知关注

    /// 关注级别变更的版本号（@Published 驱动列表刷新；值本身无意义）
    @Published private(set) var watchLevelsRevision = 0

    /// 当前 Web 壳里打开的会话（由 JS 检测回传）；用于"打开的会话默认特别关注"
    @Published private(set) var activeWebSessionId: String?

    /// 我们自动设为"特别关注"的会话（区别于用户手动设置）
    private var autoFocusedSessionId: String?

    /// 指定会话的通知关注级别；未设置过 → 跟随全局
    func watchLevel(for sessionId: String) -> WatchLevel {
        let key = "session.watch.\(sessionId)"
        guard let raw = defaults.string(forKey: key) else { return .global }
        return WatchLevel(rawValue: raw) ?? .global
    }

    /// 手动设置会话的通知关注级别（控制面板操作）。
    /// 用户手动干预后，若该会话此前是"打开自动关注"，则解除自动跟踪。
    func setWatchLevel(_ level: WatchLevel, for sessionId: String) {
        if sessionId == autoFocusedSessionId {
            autoFocusedSessionId = nil
        }
        let key = "session.watch.\(sessionId)"
        defaults.set(level.rawValue, forKey: key)
        watchLevelsRevision &+= 1
    }

    /// Web 壳会话切换回调（JS 检测到打开的会话变化时调用）。
    /// 规则：
    ///  · 新会话进入：若它还是默认的"跟随全局"（用户未手动设置过）→ 自动改为"特别关注"；
    ///  · 旧会话离开：若旧会话是我们自动关注、且用户未手动改过 → 还原为"跟随全局"。
    func sessionBecameActive(_ sessionId: String?) {
        let prev = activeWebSessionId
        activeWebSessionId = sessionId
        // 还原上一个自动关注的会话（仅当用户未手动接管）
        if let prev, let auto = autoFocusedSessionId, auto == prev, prev != sessionId,
           watchLevel(for: prev) == .focused {
            setWatchLevel(.global, for: prev)
        }
        guard let sessionId, !sessionId.isEmpty else { return }
        // 新会话：未手动设置（=跟随全局）→ 自动特别关注
        if watchLevel(for: sessionId) == .global {
            setWatchLevel(.focused, for: sessionId)
            autoFocusedSessionId = sessionId
        }
    }
}

/// 会话级通知关注级别
enum WatchLevel: String, CaseIterable, Identifiable {
    /// 跟随全局：按全局通知开关与规则推送
    case global
    /// 特别关注：全局开启时必定提醒；App 在前台也弹横幅（强化提醒）
    case focused
    /// 静音：该会话一律不推通知（灵动岛进度照常显示）
    case muted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global: return "跟随全局"
        case .focused: return "特别关注"
        case .muted: return "静音"
        }
    }

    var systemImage: String {
        switch self {
        case .global: return "bell"
        case .focused: return "bell.badge.fill"
        case .muted: return "bell.slash"
        }
    }

    var tint: Color {
        switch self {
        case .global: return .secondary
        case .focused: return .orange
        case .muted: return .gray
        }
    }
}
