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
//  控制入口：Web 设置页内注入的"App 设置"按钮 → WebShellControlSheet
//    （通知/灵动岛/会话关注/服务器与配对），原生能力集中管理；
//    新窗口链接（window.open / target=_blank）在壳内直接打开。
// ============================================================================
import SwiftUI
import UIKit
import WebKit

struct WebConsoleView: View {
    @EnvironmentObject var settings: AppSettings

    /// 是否由本视图忽略安全区铺满全屏。
    /// · true（默认，独立作为主界面使用时）：铺满全屏，网页内部自行避让状态栏/Home 条。
    /// · false（被 WebChatShellView 作为主体嵌入时）：安全区交给外层原生顶栏/输入条处理，
    ///   否则网页视图会盖住原生栏，且网页内 env(safe-area-inset-*) 会与原生栏重复补偿。
    var fillSafeArea: Bool = true

    /// 显式初始化：只暴露 fillSafeArea 与可选的外部 Coordinator。
    /// · 嵌入外壳（WebChatShellView）时传入自己持有的 Coordinator，外壳即可调用
    ///   coordinator.openSession(_:) / newSession() 在网页里切换会话。
    /// · 不传则内部自建（与 1.0 之前行为一致）。
    init(fillSafeArea: Bool = true, coordinator: Coordinator? = nil) {
        self.fillSafeArea = fillSafeArea
        self.coordinator = coordinator ?? Coordinator()
    }

    @State private var url: URL?
    @State private var loadError: String?
    @State private var pairingFailed = false
    @State private var isLoaded = false
    @State private var progress: Double = 0
    @State private var showControlSheet = false
    @State private var showSetup = false

    private let coordinator: Coordinator

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
                .modifier(SafeAreaFiller(enabled: fillSafeArea))
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
            coordinator.onSessionChanged = { sessionId in
                // Web 壳里打开的会话变化 → 自动"特别关注"当前打开的会话
                settings.sessionBecameActive(sessionId)
            }
            coordinator.onOpenControl = {
                // Web 设置页里的"App 设置"按钮 → 唤起原生控制面板
                Task { @MainActor in
                    showControlSheet = true
                }
            }
            coordinator.onPhaseChanged = { phase in
                // 会话页阶段 → 写入 settings，外层 WebChatShellView 据此显隐原生输入条
                Task { @MainActor in
                    settings.webConversationPhase = phase
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
        // 局域网优先自动探测：手动填了局域网地址时应走局域网直连（延迟低），
        // 局域网不可达时自动回落公网，避免 Web 壳永远走公网导致「局域网不生效」。
        guard let base = await settings.detectActiveBaseURL(),
              let baseURL = URL(string: base) else {
            loadError = "连不上 DSH 服务器（局域网与公网都不可达），请检查网络或重新配对。"
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
final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// 页面加载失败回调（网络错误/证书问题等 → 显示给用户）
    var onLoadError: ((String) -> Void)?
    /// 配对失败页回调（加载的页面是配对失败页 → 引导重新配对）
    var onPairingFailed: (() -> Void)?
    /// 页面加载进度回调（0…1）
    var onProgress: ((Double) -> Void)?
    /// 页面加载完成回调
    var onLoaded: (() -> Void)?
    /// Web 壳里打开的会话变化回调（JS 回传 sessionId；无会话时为 nil）
    var onSessionChanged: ((String?) -> Void)?
    /// Web 设置页"App 设置"按钮回调（JS postMessage → 唤起原生控制面板）
    var onOpenControl: (() -> Void)?
    /// 会话页阶段变化回调（JS 回传 "hero" / "active" / "settling"；无会话页为 nil）
    var onPhaseChanged: ((String?) -> Void)?
    /// 原生触发的网页导航结果（JS 回传 "opened" / "open-failed" / "created" / "create-failed"）
    var onNavResult: ((String) -> Void)?
    /// Web 内容进程崩溃后自动重载的次数（防止崩溃循环）
    private var processCrashCount = 0

    private weak var webView: WKWebView?
    private let pairingFailureMarkers = ["配对", "pair", "未授权", "授权", "设备"]

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    // MARK: WKScriptMessageHandler

    /// 接收 JS 回传的消息：
    /// - "dshSession"：当前打开的会话 ID
    /// - "dshOpenControl"：Web 设置页里的"App 设置"按钮
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "dshSession" {
            let body = message.body as? String
            let sessionId = (body?.isEmpty ?? true) ? nil : body
            Task { @MainActor [weak self] in
                self?.onSessionChanged?(sessionId)
            }
        } else if message.name == "dshOpenControl" {
            Task { @MainActor [weak self] in
                self?.onOpenControl?()
            }
        } else if message.name == "dshPhase" {
            let body = message.body as? String
            let phase = (body?.isEmpty ?? true) ? nil : body
            Task { @MainActor [weak self] in
                self?.onPhaseChanged?(phase)
            }
        } else if message.name == "dshNav" {
            let body = message.body as? String ?? ""
            Task { @MainActor [weak self] in
                self?.onNavResult?(body)
            }
        }
    }

    // MARK: 原生 → 网页

    /// 执行一段 JS（在主线程、对主框架）
    func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        webView?.evaluateJavaScript(script) { value, _ in completion?(value) }
    }

    /// 打开指定会话（网页无深链 → 代理点击侧栏对应会话行）。
    /// 只发指令；结果通过 onNavResult("opened"/"open-failed") 异步回执。
    func openSession(_ sessionId: String) {
        let escaped = sessionId.replacingOccurrences(of: "'", with: "")
        evaluate("window.__dshOpenSession ? window.__dshOpenSession('\(escaped)') : false")
    }

    /// 新建会话（代理点击网页侧栏的「新建会话」按钮）。
    /// 结果通过 onNavResult("created"/"create-failed") 回执。
    func newSession() {
        evaluate("window.__dshNewSession ? window.__dshNewSession() : false")
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
            processCrashCount = 0
            // 页面就绪后再跑一次移动端适配（SPA 可能覆盖了最初的注入）
            webView.evaluateJavaScript(WebViewCoordinator.mobileAdaptationJS, completionHandler: nil)
            checkPairingFailure(webView)
        }
    }

    /// Web 内容进程被系统回收 / 渲染崩溃：自动重载自愈。
    /// 连续崩溃超过 3 次才报错，避免崩溃-重载死循环把用户卡在白屏。
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            if processCrashCount < 3 {
                processCrashCount += 1
                webView.reload()
            } else {
                onLoadError?("网页渲染进程反复崩溃，请点「重试」或重启 App。")
            }
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

    // MARK: WKUIDelegate

    /// window.open / target="_blank" 的新窗口请求：在同一个 Web 壳里打开，
    /// 而不是丢给浏览器（WKWebView 默认忽略新窗口 → 表现为"点开没反应"）。
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 新窗口请求直接在当前 webView 里加载（SPA 内部跳转 / 设置页的子页面）
        // 非 http(s) 的私有 scheme（如 dsh-resource:// 文件预览）不接管，
        // 交给页面自身的点击处理。
        if navigationAction.targetFrame == nil,
           let scheme = navigationAction.request.url?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            Task { @MainActor in
                webView.load(navigationAction.request)
            }
        }
        return nil
    }

    /// 兜底：targetFrame == nil 的导航（target="_blank" 链接）在当前 webView 加载。
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil,
           let scheme = navigationAction.request.url?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            Task { @MainActor in
                webView.load(navigationAction.request)
            }
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    /// JS alert() → 原生弹窗（避免 Web 页 JS 对话框无响应）
    nonisolated func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            presentOnTop(alert)
        }
    }

    /// JS confirm() → 原生确认框
    nonisolated func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            presentOnTop(alert)
        }
    }

    /// 从 keyWindow 的 rootViewController 弹原生 UIAlertController
    private func presentOnTop(_ alert: UIAlertController) {
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        top?.present(alert, animated: true)
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

// MARK: - 安全区铺满开关

/// 按需给内容套上 `ignoresSafeArea(.all)`。
/// 嵌入原生外壳时必须关闭，否则 WKWebView 会盖住原生顶栏/输入条。
private struct SafeAreaFiller: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea(edges: .all)
        } else {
            content
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
        // 会话检测回传通道：JS 把当前打开的会话 ID 发给原生层
        configuration.userContentController.add(context.coordinator, name: "dshSession")
        // Web 设置页"App 设置"按钮回传通道
        configuration.userContentController.add(context.coordinator, name: "dshOpenControl")
        // 会话页阶段回传通道（hero / active / settling → 原生输入条显隐）
        configuration.userContentController.add(context.coordinator, name: "dshPhase")
        // 原生触发的网页导航回执通道（打开会话 / 新建会话的结果）
        configuration.userContentController.add(context.coordinator, name: "dshNav")

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

      // ---- DOM 就绪后执行 ----
      // WKUserScript 在 atDocumentStart 注入时 head/body 尚未解析（document.head 为
      // null），直接在此时操作 DOM 会抛 TypeError 导致后续注入全部中断；因此先等
      // DOMContentLoaded（已就绪则立即执行），didFinish 重跑时被幂等标志挡住。
      function whenReady(fn) {
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', fn);
        } else {
          fn();
        }
      }

      // ---- 原生层可调用的窗口 API ----
      // 网页没有会话深链（URL 不携带 sessionId），打开会话的唯一通道是点击侧栏里
      // 对应的会话行：官方侧栏行是 div[role=treeitem][data-row-key="session:<id>"]，
      // 自身带 onClick → onOpen(id)。行可能因窄屏侧栏折叠 / 分组合并 / 列表虚拟化
      // 而不在 DOM 中，所以：直接点 → 展开分组与"更多"再点 → 250ms 间隔重试 8 次。
      // 结果通过 messageHandlers.dshNav 回执（opened / open-failed / created /
      // create-failed），原生层据此给用户明确反馈。
      function dshNavReport(text) {
        try { window.webkit.messageHandlers.dshNav.postMessage(text); } catch (e) { /* 未注册时忽略 */ }
      }

      function dshFindSessionRow(id) {
        try { return document.querySelector('[data-row-key="session:' + id + '"]'); } catch (e) { return null; }
      }

      function dshClickSessionRow(id) {
        var row = dshFindSessionRow(id);
        if (!row) { return false; }
        try { row.scrollIntoView({ block: 'nearest' }); } catch (e) {}
        try { row.click(); } catch (e) { return false; }
        return true;
      }

      // 展开所有折叠的工作区分组与「显示更多会话」
      function dshExpandSessionGroups() {
        var nodes = document.querySelectorAll('[data-row-key^="workspace:"], [data-row-key^="overflow:"]');
        for (var i = 0; i < nodes.length; i++) {
          try {
            if (nodes[i].getAttribute('aria-expanded') === 'false') { nodes[i].click(); }
          } catch (e) {}
        }
      }

      window.__dshOpenSession = function (id) {
        if (!id) { return false; }
        if (dshClickSessionRow(id)) { dshNavReport('opened'); return true; }
        dshExpandSessionGroups();
        if (dshClickSessionRow(id)) { dshNavReport('opened'); return true; }
        var attempt = 0;
        (function retry() {
          attempt += 1;
          setTimeout(function () {
            if (dshClickSessionRow(id)) { dshNavReport('opened'); return; }
            dshExpandSessionGroups();
            if (dshClickSessionRow(id)) { dshNavReport('opened'); return; }
            if (attempt < 8) { retry(); } else { dshNavReport('open-failed'); }
          }, 250);
        })();
        return false;
      };

      // 新建会话：点官方侧栏工作区行里的「新建会话」按钮（aria-label 带会话名）
      // 窄屏时侧栏可能整体收起（<1024px 收成 56px 轨道）导致按钮不在 DOM 中，
      // 因此找不到时先尝试展开侧栏，再以 250ms 间隔重试若干次。
      window.__dshNewSession = function () {
        function findNewSessionButton() {
          var nodes = document.querySelectorAll('button[aria-label], [role="button"][aria-label], a[aria-label]');
          for (var i = 0; i < nodes.length; i++) {
            var label = nodes[i].getAttribute('aria-label') || '';
            var lower = label.toLowerCase();
            if (label.indexOf('新建会话') >= 0 || label.indexOf('新会话') >= 0 || lower.indexOf('new session') >= 0) {
              return nodes[i];
            }
          }
          return null;
        }
        function expandSidebar() {
          var nodes = document.querySelectorAll('button[aria-label], [role="button"][aria-label]');
          for (var i = 0; i < nodes.length; i++) {
            var label = nodes[i].getAttribute('aria-label') || '';
            if (/侧栏|侧边栏|sidebar|导航/i.test(label)) {
              try { nodes[i].click(); } catch (e) {}
              return true;
            }
          }
          return false;
        }
        var target = findNewSessionButton();
        if (!target) {
          expandSidebar();
          target = findNewSessionButton();
        }
        if (target) {
          try { target.click(); } catch (e) { dshNavReport('create-failed'); return false; }
          dshNavReport('created');
          return true;
        }
        var attempt = 0;
        (function retry() {
          attempt += 1;
          setTimeout(function () {
            var button = findNewSessionButton();
            if (button) {
              try { button.click(); } catch (e) { /* 落到下一次重试 */ }
              dshNavReport('created');
              return;
            }
            if (attempt === 3) { expandSidebar(); }
            if (attempt < 8) { retry(); } else { dshNavReport('create-failed'); }
          }, 250);
        })();
        return false;
      };

      function ensureViewport() {
        var content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
        var meta = document.querySelector('meta[name="viewport"]');
        if (meta) {
          meta.setAttribute('content', content);
        } else {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          meta.content = content;
          (document.head || document.documentElement).appendChild(meta);
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
          // 顶部安全区：灵动岛/刘海/状态栏避让。会话页顶部栏（header 等）在正常
          // 文档流，给它们加顶部安全区 padding，内容不再延伸进灵动岛/时间电量区域。
          // 但模态（role=dialog / data-shortcut-modal）内部的 header 是模态自己的
          // 头部，居中显示不受状态栏影响，必须排除，否则模态头部会被顶下去。
          '[class*="header"], [class*="topbar"], [class*="titlebar"], [class*="navBar"], [class*="navbar"], [class*="appBar"] {',
          '  padding-top: env(safe-area-inset-top, 0px) !important;',
          '}',
          '[role="dialog"] [class*="header"], [data-shortcut-modal] [class*="header"],',
          '[role="dialog"] [class*="topbar"], [data-shortcut-modal] [class*="topbar"] {',
          '  padding-top: 0 !important;',
          '}',
          // 原生输入条接管（WebChatShellView）—— 互斥不变式：
          // 只有当原生输入条**确实已经在屏幕上**时（JS 判定当前是会话页且拿到非空
          // 会话 id，会给 <html> 打上 .dsh-native-composer），才隐藏网页自带的输入区。
          // 判定与原生输入条的显示条件出自同一段 JS 的同一组取值，两者不可能同时为假
          // —— 任何桥接失败/属性缺失都只是回到"网页输入条兜底"，绝不会出现"没有输入框"。
          'html.dsh-native-composer [data-composer-seat] {',
          '  display: none !important;',
          '}',
          '@media (max-width: 600px) {',
          // 核心：桌面版把内容宽度 clamp 在 680px+，在 iPhone 上必然横向溢出
          // → 覆盖为视口宽度，聊天内容与输入框不再被挤出去
          '  :root, html, body {',
          '    --dsh-chat-content-width: min(calc(100vw - 16px), 920px) !important;',
          '    --dsh-composer-card-max-width: calc(100vw - 16px) !important;',
          '    --dsh-composer-side-clearance: 8px !important;',
          '    --dsh-composer-dock-inset: 8px !important;',
          '    --dsh-composer-text-max-height: 40vh !important;',
          '  }',
          // 输入区（CSS-in-JS 运行时类名带 composerSeat/composerHero 前缀，用属性匹配）
          // 底部安全区：Home 指示条避让，发送/附件等按钮不再被遮挡
          '  [class*="composerSeat"] { padding-bottom: max(env(safe-area-inset-bottom), 12px) !important; }',
          '  [class*="composerHero"] { width: 100% !important; padding-bottom: 10px !important; }',
          '  [class*="composerStack"] { gap: 4px !important; }',
          '  [class*="editor"] { font-size: 16px !important; }',
          '  button, a[href], [role="button"], [type="button"], [type="submit"] { min-height: 40px; }',
          '}'
        ].join('\\n');
        (document.head || document.documentElement).appendChild(style);
      }

      // ---- 会话检测：把"当前打开的会话"回传给原生层 ----
      // 官方会话 UI 在打开的会话 body 上挂 data-conversation-session 属性；
      // 无该元素（列表页/设置页）表示当前没有打开的会话。
      function startSessionWatch() {
        if (window.__dshSessionWatchStarted) { return; }
        window.__dshSessionWatchStarted = true;
        var last = null;
        var lastPhase = null;
        function currentSessionId() {
          // 属性可能被渲染成空串（React 传 null 时 attribute=""），空串按"没有会话"处理
          var el = document.querySelector('[data-conversation-session]');
          var id = el ? (el.getAttribute('data-conversation-session') || '') : '';
          if (!id) {
            // 兜底：侧栏里被选中的会话行（行自带 aria-selected）
            var row = document.querySelector('[data-row-key^="session:"][aria-selected="true"]');
            if (row) {
              id = (row.getAttribute('data-row-key') || '').replace(/^session:/, '');
            }
          }
          return id ? id : null;
        }
        // 会话页阶段：hero=首屏（新建会话）/ active=会话进行中 / settling=收尾。
        // 原生层据此决定是否显示原生输入条（hero 交给网页首屏输入框）。
        function currentPhase() {
          // 优先读对话内容容器上的 data-content-phase：它与 data-conversation-session
          // 挂在同一个元素上，值域是 hero / active / settling，正是我们要的页面阶段。
          // 注意 composer 内部的可编辑框也带 data-phase，但取值是 plain / submitting /
          // adjudicating 等编辑态，不能用来判断页面阶段，只作最后兜底。
          var body = document.querySelector('[data-content-phase]');
          var phase = body ? body.getAttribute('data-content-phase') : null;
          if (!phase) {
            var el = document.querySelector('[data-phase]');
            phase = el ? el.getAttribute('data-phase') : null;
          }
          return phase;
        }
        // 原生输入条是否应当接管（与 Swift 侧 WebChatShellView.isConversationPage 同源：
        // 有非空会话 id 且不在 hero 首屏）。为 true 时给 <html> 打标记，CSS 才隐藏
        // 网页自带输入区；否则网页输入条始终可见 —— 桥接任何一环失败都不会没有输入框。
        function syncNativeComposer(id, phase) {
          var root = document.documentElement;
          if (!root || !root.classList) { return; }
          var native = !!id && phase !== 'hero';
          if (native !== root.classList.contains('dsh-native-composer')) {
            root.classList.toggle('dsh-native-composer', native);
          }
        }
        function report() {
          var id = currentSessionId();
          var phase = currentPhase();
          syncNativeComposer(id, phase);
          if (id !== last) {
            last = id;
            try {
              window.webkit.messageHandlers.dshSession.postMessage(id || '');
            } catch (e) { /* 原生侧未注册时忽略 */ }
          }
          if (phase !== lastPhase) {
            lastPhase = phase;
            try {
              window.webkit.messageHandlers.dshPhase.postMessage(phase || '');
            } catch (e) { /* 原生侧未注册时忽略 */ }
          }
        }
        report();
        try {
          var mo = new MutationObserver(function () { report(); });
          mo.observe(document.documentElement, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ['data-conversation-session', 'data-phase', 'data-content-phase']
          });
        } catch (e) {}
        // 兜底轮询（SPA 极端重渲染下 MutationObserver 可能漏报）
        setInterval(report, 2000);
      }

      // ---- Web 设置页注入"App 设置"按钮 ----
      // 原生悬浮齿轮按钮已移除；改在 Web 设置页（data-shortcut-modal="settings"
      // 模态）的头部注入一个"App 设置"按钮，点击 → postMessage → 原生控制面板。
      // 幂等：同一元素存在时不重复创建；模态关闭（DOM 卸载）后自动随组件消失。
      function injectAppSettingsButton() {
        if (window.__dshAppSettingsBtnStarted) { return; }
        window.__dshAppSettingsBtnStarted = true;
        function findPanel() {
          return document.querySelector('[data-shortcut-modal="settings"]');
        }
        function ensureButton() {
          var panel = findPanel();
          if (!panel) { return; }
          if (document.getElementById('dsh-app-settings-btn')) { return; }
          var btn = document.createElement('button');
          btn.id = 'dsh-app-settings-btn';
          btn.type = 'button';
          btn.textContent = 'App 设置';
          btn.style.cssText = [
            'position:absolute',
            'right:44px',
            'top:12px',
            'z-index:9999',
            'padding:6px 12px',
            'border-radius:999px',
            'border:1px solid rgba(168,85,247,.45)',
            'background:rgba(168,85,247,.14)',
            'color:var(--dsw-alias-label-primary,#e9d5ff)',
            'font-size:13px',
            'font-weight:600',
            'line-height:20px',
            'cursor:pointer',
            'display:inline-flex',
            'align-items:center',
            'gap:4px',
            'min-height:32px',
            'touch-action:manipulation',
            'backdrop-filter:blur(6px)',
            '-webkit-backdrop-filter:blur(6px)'
          ].join(';');
          btn.addEventListener('click', function () {
            try {
              window.webkit.messageHandlers.dshOpenControl.postMessage('open');
            } catch (e) { /* 原生侧未注册时忽略 */ }
          });
          panel.style.position = 'relative';
          panel.appendChild(btn);
        }
        ensureButton();
        try {
          new MutationObserver(function () { ensureButton(); }).observe(
            document.documentElement, { childList: true, subtree: true }
          );
        } catch (e) {}
        setInterval(ensureButton, 1000);
      }

      // ---- 启动（DOM 就绪后执行全部注入）----
      whenReady(function () {
        if (window.__dshMobileAdapted) { return; }
        window.__dshMobileAdapted = true;
        try { ensureViewport(); } catch (e) {}
        try { injectStyle(); } catch (e) {}
        startSessionWatch();
        injectAppSettingsButton();
      });
    })();
    """
}
