// ============================================================================
//  WebConsoleView.swift — App 主界面（App 化 Web 壳，承载官方 DSH Web）
//  ----------------------------------------------------------------------------
//  目标：像拼多多那样的「网页内容 + App 体验」——官方 DSH Web 即 App 主体，
//  全屏沉浸式 WKWebView：无地址栏、无浏览器工具栏，顶部细进度条 + 下拉刷新。
//
//  移动端适配（关键，解决 iPhone 直访拥挤/点不到/元素消失）：
//    加载前注入 WKUserScript（documentStart）+ 加载完成后再次 evaluate：
//      · 强制 viewport = device-width（禁止缩放，避免 iOS 自动放大）
//      · overflow-x: hidden 防横向溢出裁切（元素「消失」的根因之一）
//      · 输入控件 16px 字号（iOS 聚焦时自动放大导致「点不到」）
//      · 触控目标 ≥40px + touch-action: manipulation（去双击延迟）
//
//  身份注入：
//    远程设备靠 dsh_pair cookie（= deviceId）被服务端识别为已配对设备。
//    App 原生配对已持有有效 deviceId，加载前以 dsh_pair cookie 注入
//    WKWebView 的 cookie store，免重新扫码直接进入官方 GUI（/pair-app）。
//    若 deviceId 失效，web 显示配对失败页 → 引导重新配对。
//
//  控制入口：右下角悬浮齿轮 → WebShellControlSheet（通知/灵动岛/会话关注/
//    服务器与配对），原生能力集中管理。
// ============================================================================
import SwiftUI
import WebKit

struct WebConsoleView: View {
    @EnvironmentObject var settings: AppSettings

    @State private var url: URL?
    @State private var loadError: String?
    @State private var pairingFailed = false
    @State private var isLoaded = false
    @State private var progress: Double = 0
    @State private var showControlSheet = false
    @State private var showSetup = false

    private let coordinator = Coordinator()

    var body: some View {
        Group {
            if loadError != nil {
                errorView
            } else if pairingFailed {
                pairingFailedView
            } else if let url {
                WebViewRepresentable(
                    url: url,
                    coordinator: coordinator,
                    onProgress: { progress = $0 },
                    onLoaded: { isLoaded = true }
                )
                .ignoresSafeArea(edges: .all)
                .overlay(alignment: .top) {
                    // 细进度条：仅加载中显示
                    if progress < 1 {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.purple)
                            .frame(height: 2)
                            .opacity(isLoaded ? 0 : 1)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // 右下角悬浮控制按钮（App 感）
                    Button {
                        showControlSheet = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 20)
                    .accessibilityLabel("App 控制")
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                }
            } else {
                ProgressView("正在连接…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showControlSheet) {
            WebShellControlSheet(onReload: { coordinator.reload() })
                .environmentObject(settings)
        }
        .fullScreenCover(isPresented: $showSetup) {
            SetupView(mode: .settings)
                .environmentObject(settings)
        }
        .task {
            coordinator.onLoadError = { msg in
                Task { @MainActor in
                    loadError = msg
                }
            }
            coordinator.onPairingFailed = {
                Task { @MainActor in
                    pairingFailed = true
                }
            }
            await prepareURL()
        }
        // 重新配对后 deviceId 变化 → 重新注入 cookie 并强制刷新
        .onChange(of: settings.deviceId) { _, _ in
            Task {
                await prepareURL()
                coordinator.reload()
            }
        }
    }

    // MARK: - 准备 URL + 注入设备 cookie

    private func prepareURL() async {
        guard let base = settings.webConsoleBaseURL(),
              let baseURL = URL(string: base) else {
            loadError = "未配置服务器地址，请先在「配对与服务器设置」中完成配对。"
            return
        }
        let target = baseURL.appendingPathComponent("pair-app")

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
            Button("服务器设置") { showSetup = true }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pairingFailedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.key")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("设备配对已失效").font(.headline)
            Text("Web 界面未识别到本机的配对身份。请重新扫码配对后自动回到这里。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("重新配对") { showSetup = true }
                .buttonStyle(.borderedProminent)
            Button("重试") {
                pairingFailed = false
                Task { await prepareURL(); coordinator.reload() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Coordinator（桥接 WKWebView 代理事件）

@MainActor
final class Coordinator: NSObject, WKNavigationDelegate {
    /// 页面加载失败回调（网络错误/证书问题等 → 显示给用户）
    var onLoadError: ((String) -> Void)?
    /// 配对失败页回调（加载的页面是配对失败页 → 引导重新配对）
    var onPairingFailed: (() -> Void)?
    /// 页面加载进度回调（0…1）
    var onProgress: ((Double) -> Void)?
    /// 页面加载完成回调
    var onLoaded: (() -> Void)?

    private weak var webView: WKWebView?
    private let pairingFailureMarkers = ["配对", "pair", "未授权", "授权", "设备"]

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
    }

    /// 下拉刷新 / 手动重载
    func reload() {
        webView?.reload()
    }

    /// 下拉刷新 target-action（UIRefreshControl 挂在滚动视图上）
    @objc func didPullRefresh(_ sender: UIRefreshControl) {
        reload()
        sender.endRefreshing()
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            onProgress?(0.15)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            onProgress?(1)
            onLoaded?()
            // 页面就绪后再跑一次移动端适配（SPA 可能覆盖了最初的注入）
            webView.evaluateJavaScript(WebViewCoordinator.mobileAdaptationJS, completionHandler: nil)
            checkPairingFailure(webView)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let ns = error as NSError
            if ns.code != NSURLErrorCancelled {
                onLoadError?("加载失败：\(ns.localizedDescription)（\(ns.domain) · \(ns.code)）")
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let ns = error as NSError
            if ns.code != NSURLErrorCancelled {
                onLoadError?("加载失败：\(ns.localizedDescription)（\(ns.domain) · \(ns.code)）")
            }
        }
    }

    // MARK: 内部

    /// 启发式判断当前页面是否为配对失败页（URL path 是 pair 且标题含配对相关标记）
    private func checkPairingFailure(_ webView: WKWebView) {
        guard let url = webView.url else { return }
        let title = webView.title?.lowercased() ?? ""
        let path = url.path.lowercased()
        let looksLikePairingPage = path.contains("pair")
        let titleHintsPairing = pairingFailureMarkers.contains { title.contains($0) }
        if looksLikePairingPage && titleHintsPairing {
            onPairingFailed?()
        }
    }
}

// MARK: - WebViewRepresentable（UIViewRepresentable 封装）

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    let coordinator: Coordinator
    var onProgress: (Double) -> Void
    var onLoaded: () -> Void

    func makeCoordinator() -> Coordinator { coordinator }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 移动端适配：documentStart 注入，保证 SPA 首帧前就生效
        let userScript = WKUserScript(
            source: WebViewCoordinator.mobileAdaptationJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(userScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.refreshControl = UIRefreshControl()
        webView.scrollView.refreshControl?.addTarget(
            context.coordinator,
            action: #selector(Coordinator.didPullRefresh(_:)),
            for: .valueChanged
        )
        context.coordinator.attach(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil || webView.url?.host != url.host {
            webView.load(URLRequest(url: url))
        }
    }
}

// MARK: - WebViewCoordinator（工具）

extension WebViewCoordinator {
    /// 共享的 default cookie store（WKWebsiteDataStore.default() 主线程访问）
    static func sharedCookieStore() async -> WKHTTPCookieStore {
        await MainActor.run {
            WKWebsiteDataStore.default().httpCookieStore
        }
    }
}

/// 工具类型：承载移动端适配 JS（WKUserScript 注入源）与 cookie store 访问。
enum WebViewCoordinator {
    /// 移动端响应式适配脚本（幂等：window 标志位防重复执行）。
    /// 处理 iPhone 直访 web UI 的三大问题：拥挤、点不到、元素消失。
    static let mobileAdaptationJS = """
    (function () {
      'use strict';
      if (window.__dshMobileAdapted) { return; }
      window.__dshMobileAdapted = true;

      function ensureViewport() {
        var content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
        var meta = document.querySelector('meta[name="viewport"]');
        if (meta) {
          meta.setAttribute('content', content);
        } else {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          meta.content = content;
          document.head.appendChild(meta);
        }
      }

      function injectStyle() {
        if (document.getElementById('dsh-mobile-adapt')) { return; }
        var style = document.createElement('style');
        style.id = 'dsh-mobile-adapt';
        style.textContent = [
          'html, body { max-width: 100%; overflow-x: hidden; }',
          'body { -webkit-text-size-adjust: 100%; }',
          'input, textarea, select { font-size: 16px !important; }',
          'button, a, [role="button"], [type="button"], [type="submit"], input[type="submit"] { touch-action: manipulation; }',
          '@media (max-width: 480px) {',
          '  button, a[href], [role="button"], [type="button"], [type="submit"] { min-height: 40px; }',
          '}'
        ].join('\\n');
        document.head.appendChild(style);
      }

      ensureViewport();
      injectStyle();
    })();
    """
}
