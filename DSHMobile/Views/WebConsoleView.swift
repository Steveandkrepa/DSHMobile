// ============================================================================
//  WebConsoleView.swift — 完整 Web 界面（WKWebView 承载官方 DSH Web）
//  ----------------------------------------------------------------------------
//  背景：
//    纯 Swift 的 schema 表单无法覆盖 web 的全部设置/凭证/模型管理等功能，
//    因此 App 内嵌官方 DSH Web 界面作为「完整功能」入口——web 功能一个不少。
//
//  身份注入（关键）：
//    远程设备的 web 界面靠 dsh_pair cookie（= deviceId）被服务端识别为
//    「已配对设备」，从而放行 /remote 受控通道并渲染官方 GUI（/pair-app）。
//    App 原生配对已持有有效 deviceId，加载前把它以 dsh_pair cookie 注入
//    WKWebView 的 cookie store，即可免重新扫码、免消耗新 token 直接进入。
//    若 deviceId 已被撤销/过期，web 会显示配对失败页，此时引导重新配对。
// ============================================================================
import SwiftUI
import WebKit

struct WebConsoleView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var url: URL?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var pairingFailed = false

    /// 供 WKWebView 刷新用
    @State private var reloadToken = 0

    private let coordinator = Coordinator()

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具条：地址 + 导航
            toolbarBar
            Divider()

            if loadError != nil {
                errorView
            } else if pairingFailed {
                pairingFailedView
            } else {
                WebViewRepresentable(
                    url: url,
                    reloadToken: reloadToken,
                    coordinator: coordinator
                )
                .overlay(alignment: .bottom) {
                    if isLoading {
                        ProgressView()
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(.thinMaterial)
                    }
                }
            }
        }
        .navigationTitle("完整 Web 界面")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .task {
            coordinator.onLoadError = { msg in
                Task { @MainActor in
                    loadError = msg
                }
            }
            await prepareURL()
        }
        .onChange(of: coordinator.pairingFailed) { _, failed in
            if failed { pairingFailed = true }
        }
    }

    // MARK: - 准备 URL + 注入设备 cookie

    private func prepareURL() async {
        // 1. 确定 base：公网优先（隧道域名与 cookie 域名一致），否则局域网
        guard let base = settings.webConsoleBaseURL(),
              let baseURL = URL(string: base) else {
            loadError = "未配置服务器地址，请先在「配对与服务器设置」中完成配对。"
            return
        }
        let target = baseURL.appendingPathComponent("pair-app")

        // 2. 注入 dsh_pair cookie（= 已配对 deviceId），公网 + 局域网两个域名都注入
        guard !settings.deviceId.isEmpty else {
            loadError = "尚未配对设备，请先完成配对。"
            return
        }
        let cookieStore = await WebViewCoordinator.sharedCookieStore()
        var hosts: [String] = []
        if !settings.publicURL.isEmpty, let pubURL = URL(string: settings.publicURL), let host = pubURL.host {
            hosts.append(host)
        }
        if !settings.lanURL.isEmpty, let lanURL = URL(string: settings.lanURL), let host = lanURL.host {
            if !hosts.contains(host) { hosts.append(host) }
        }
        for host in hosts {
            if let cookie = makeDeviceCookie(host: host, deviceId: settings.deviceId) {
                await cookieStore.setCookie(cookie)
            }
        }

        url = target
    }

    /// 构造 dsh_pair 设备 cookie（与 web 服务端 deviceCookie 格式一致）
    private func makeDeviceCookie(host: String, deviceId: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .domain: host,
            .path: "/",
            .name: "dsh_pair",
            .value: deviceId,
            .expires: Date(timeIntervalSinceNow: 10 * 365 * 24 * 3600), // 10 年
            .init(rawValue: "HttpOnly"): "TRUE",
            .init(rawValue: "SameSite"): "Lax"
        ])
    }

    // MARK: - 子视图

    private var toolbarBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await coordinator.goBack() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!coordinator.canGoBack)

            Button {
                Task { await coordinator.goForward() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!coordinator.canGoForward)

            Button {
                Task { await coordinator.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }

            Spacer()

            if let url, let scheme = url.scheme {
                Text(displayHost(url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                openInSafari()
            } label: {
                Image(systemName: "safari")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .buttonStyle(.borderless)
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("无法打开 Web 界面").font(.headline)
            Text(loadError ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("重试") {
                loadError = nil
                Task { await prepareURL() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pairingFailedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.key")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("设备配对已失效").font(.headline)
            Text("Web 界面未识别到本机的配对身份。请在「设置 → 配对与服务器设置」中重新扫码配对，然后回到这里重试。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("关闭") { dismiss() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayHost(_ url: URL) -> String {
        url.host ?? url.absoluteString
    }

    private func openInSafari() {
        guard let url else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Coordinator（桥接 WKWebView 代理事件）

@MainActor
final class Coordinator: NSObject, WKNavigationDelegate {
    var canGoBack = false
    var canGoForward = false
    var pairingFailed = false
    /// 页面加载失败回调（网络错误/证书问题等 → 显示给用户）
    var onLoadError: ((String) -> Void)?

    private weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
    }

    func goBack() async {
        webView?.goBack()
        refreshState()
    }

    func goForward() async {
        webView?.goForward()
        refreshState()
    }

    func reload() async {
        webView?.reload()
    }

    private func refreshState() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            refreshState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            refreshState()
            let ns = error as NSError
            // 用户主动取消的导航不算错误
            if ns.code != NSURLErrorCancelled {
                onLoadError?("加载失败：\(ns.localizedDescription)（\(ns.domain) · \(ns.code)）")
            }
        }
    }
}

// MARK: - WebViewRepresentable（UIViewRepresentable 封装）

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL?
    let reloadToken: Int
    let coordinator: Coordinator

    @State private var internalWebView: WKWebView?

    func makeCoordinator() -> Coordinator { coordinator }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(webView)
        DispatchQueue.main.async {
            internalWebView = webView
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let url, webView.url != url {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
}

// MARK: - WKWebsiteDataStore 共享访问（Swift 并发适配）

extension WebViewCoordinator {
    /// 共享的 default cookie store（WKWebsiteDataStore.default() 主线程访问）
    static func sharedCookieStore() async -> WKHTTPCookieStore {
        await MainActor.run {
            WKWebsiteDataStore.default().httpCookieStore
        }
    }
}

/// 占位类型：仅用于把 WKHTTPCookieStore 的并发访问集中到 MainActor
enum WebViewCoordinator {}
