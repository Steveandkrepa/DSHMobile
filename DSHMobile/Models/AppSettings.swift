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

@MainActor
final class AppSettings: ObservableObject {
    // MARK: - 持久化键
    private enum Key {
        static let lanURL = "settings.lanURL"
        static let publicURL = "settings.publicURL"
        static let deviceId = "settings.deviceId"
        static let paired = "settings.paired"
    }

    // MARK: - 状态
    @Published var lanURL: String = UserDefaults.standard.string(forKey: Key.lanURL) ?? ""
    @Published var publicURL: String = UserDefaults.standard.string(forKey: Key.publicURL) ?? ""
    @Published var deviceId: String = UserDefaults.standard.string(forKey: Key.deviceId) ?? ""
    @Published var isPaired: Bool = UserDefaults.standard.bool(forKey: Key.paired)

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
}
