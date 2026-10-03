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
//  原生能力入口：全部在原生外壳（WebChatShellView）里——顶栏齿轮菜单 → App 设置
//    （通知/灵动岛/会话特别关注/服务器与配对），网页内不再注入任何原生入口；
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
    /// · reloadRequest 变化一次 = 请求一次彻底刷新（重新探测基址 + 重注入 cookie
    ///   后回到 /pair-app）——外壳的"重新加载网页"与抽屉里的刷新都走这条路。
    init(fillSafeArea: Bool = true, coordinator: Coordinator? = nil, reloadRequest: Int = 0) {
        self.fillSafeArea = fillSafeArea
        self.coordinator = coordinator ?? Coordinator()
        self.reloadRequest = reloadRequest
    }

    /// 外壳请求刷新的计数（每 +1 触发一次刷新）
    var reloadRequest: Int = 0

    @State private var url: URL?
    @State private var loadError: String?
    @State private var pairingFailed = false
    @State private var isLoaded = false
    @State private var progress: Double = 0
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
            coordinator.onPhaseChanged = { phase in
                // 会话页阶段 → 写入 settings，外层 WebChatShellView 据此显隐原生输入条
                Task { @MainActor in
                    settings.webConversationPhase = phase
                }
            }
            coordinator.onComposerChanged = { owns in
                // 原生输入条是否接管：false（网页正在提问/等权限确认）时原生条让位
                Task { @MainActor in
                    settings.nativeComposerActive = owns
                }
            }
            await prepareURL()
        }
        // 外壳请求刷新：重新探测基址 + 重注入 cookie，然后回到 /pair-app 入口
        .onChange(of: reloadRequest) { _, _ in
            Task { await handleReloadRequest() }
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
        // 记住认证入口：刷新必须回到 /pair-app（局域网上的 / 是配对页）
        coordinator.entryURL = target
    }

    /// 外壳请求的彻底刷新：重新探测基址（局域网/公网可能已切换）+ 重注入设备 cookie，
    /// 再回到 /pair-app 入口加载。基址变了就交给 updateUIView（url 变化会自己加载）。
    private func handleReloadRequest() async {
        let previousHost = coordinator.entryURL?.host
        loadError = nil
        pairingFailed = false
        await prepareURL()
        guard loadError == nil else { return }
        if coordinator.entryURL?.host != previousHost { return }
        coordinator.reload()
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
                // 必须显式 reload：prepareURL 只是重新算 url，宿主不变时
                // updateUIView 不会触发新的加载（旧实现在这里点了没反应）
                Task { await prepareURL(); coordinator.reload() }
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
    /// 会话页阶段变化回调（JS 回传 "hero" / "active" / "settling"；无会话页为 nil）
    var onPhaseChanged: ((String?) -> Void)?
    /// 原生输入条是否接管网页输入（JS 回传 "native" / "web"）。
    /// "web" 表示网页 composer 正被提问卡/权限确认接管 —— 此时原生输入条必须让位。
    var onComposerChanged: ((Bool) -> Void)?
    /// 原生触发的网页导航结果（JS 回传 "opened" / "open-failed" / "created" / "create-failed"）
    var onNavResult: ((String) -> Void)?
    /// Web 内容进程崩溃后自动重载的次数（防止崩溃循环）
    private var processCrashCount = 0

    /// 认证入口 URL（{base}/pair-app）。刷新必须回到它：
    /// /pair-app 首帧脚本会把地址栏改写成 /（history.replaceState），而局域网来源的 /
    /// 由配对页接管（root-auth 插件认领了精确的 /）——直接 webView.reload() 会看到
    /// "设备未配对"，冷启动重新 load(/pair-app) 才正常。明文 HTTP 的局域网没有
    /// service worker 兜底，所以必须由原生记住入口 URL。
    var entryURL: URL?
    /// 最近一次已知的会话 ID（刷新 / 崩溃自愈后用于自动回到原会话）
    private var lastSessionId: String?
    /// 本次页面加载完成后待恢复的会话 ID（nil = 无需恢复）
    private var restoreSessionId: String?
    /// 正在自动恢复会话：这期间打开失败不打扰用户（不报 onNavResult 错误）
    private var isRestoringSession = false

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
    /// - "dshPhase"：会话页阶段
    /// - "dshComposer"：原生输入条是否接管（native / web）
    /// - "dshNav"：原生触发的网页导航回执
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "dshSession" {
            let body = message.body as? String
            let sessionId = (body?.isEmpty ?? true) ? nil : body
            Task { @MainActor [weak self] in
                self?.lastSessionId = sessionId
                self?.onSessionChanged?(sessionId)
            }
        } else if message.name == "dshPhase" {
            let body = message.body as? String
            let phase = (body?.isEmpty ?? true) ? nil : body
            Task { @MainActor [weak self] in
                self?.onPhaseChanged?(phase)
            }
        } else if message.name == "dshComposer" {
            let owns = (message.body as? String) == "native"
            Task { @MainActor [weak self] in
                self?.onComposerChanged?(owns)
            }
        } else if message.name == "dshNav" {
            let body = message.body as? String ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 刷新后自动回原会话：失败不打扰用户（用户没主动点过）
                if self.isRestoringSession {
                    self.isRestoringSession = false
                    return
                }
                self.onNavResult?(body)
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

    /// 下拉刷新 / 手动重载：回到认证入口 /pair-app，而不是地址栏里的当前地址。
    /// 原因（局域网"刷新后显示未配对"的根因）：/pair-app 的首帧脚本会
    /// history.replaceState(null, '', '/') 把地址栏改写成 /；而局域网来源的 /
    /// 由配对页（lan-root-auth 插件认准的精确 / 路由）接管 —— 直接 webView.reload()
    /// 请求的就是 /，于是看到"设备未配对"；冷启动重新 load(/pair-app) 带 dsh_pair
    /// cookie 才正常。明文 HTTP 的局域网不是安全上下文，service worker 不注册，
    /// 没有兜底，只能由原生记住入口 URL。
    /// 顺带记住当前会话，加载完成后自动回到原会话。
    func reload() {
        restoreSessionId = lastSessionId
        // 页面即将重载：旧值不再代表"网页当前打开的会话"，
        // 清空后 restoreSessionIfNeeded 才能区分"网页还没报"与"网页已自己恢复"
        lastSessionId = nil
        if let entryURL {
            webView?.load(URLRequest(url: entryURL))
        } else {
            webView?.reload()
        }
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
            restoreSessionIfNeeded()
        }
    }

    /// 刷新/崩溃自愈后：等网页稳定，如果它没有自己回到原会话，就代理点击恢复。
    /// 失败静默处理（用户没主动请求，不该弹错误）。
    private func restoreSessionIfNeeded() {
        guard let pending = restoreSessionId else { return }
        restoreSessionId = nil
        isRestoringSession = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self else { return }
            if self.lastSessionId == nil {
                self.openSession(pending)
                // 兜底：网页一直不回执时别让"自动恢复"状态一直吞掉后续回执
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self.isRestoringSession = false
            } else {
                self.isRestoringSession = false
            }
        }
    }

    /// Web 内容进程被系统回收 / 渲染崩溃：自动重载自愈。
    /// 连续崩溃超过 3 次才报错，避免崩溃-重载死循环把用户卡在白屏。
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            if processCrashCount < 3 {
                processCrashCount += 1
                reload()   // 回到 /pair-app 入口，而不是崩溃时的地址
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
        // 会话页阶段回传通道（hero / active / settling → 原生输入条显隐）
        configuration.userContentController.add(context.coordinator, name: "dshPhase")
        // 原生输入条接管回传通道（native / web → 提问/权限确认时原生条必须让位）
        configuration.userContentController.add(context.coordinator, name: "dshComposer")
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
          // 只有当原生输入条**确实已经在屏幕上**时（JS 判定当前是会话页、拿到非空
          // 会话 id，并且网页 composer 里确实存在真正的输入框 [data-composer-input]），
          // 才隐藏网页那一条输入栏。判定与原生输入条的显示条件出自同一段 JS 的同一组
          // 取值，两者不可能同时为假 —— 任何桥接失败/属性缺失都只是回到"网页输入条兜底"，
          // 绝不会出现"没有输入框"。
          //
          // 关键：只隐藏"含输入框的那一层"（JS 打上 data-dsh-native-hide），
          // 绝不能隐藏整个 [data-composer-seat] —— seat 里还挂着
          // 「任务清单 TodoDock」「排队 QueueDock」等卡片，以及「提问 / 权限确认」
          // 接管 composer 的卡片，它们必须保持可见可点。
          'html.dsh-native-composer [data-dsh-native-hide="1"] {',
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
        var lastOwns = null;
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
        // 网页 composer 里"承载真正输入框的那一条"：composer stack 的直接子元素中，
        // 包含 [data-composer-input]（官方输入框的 contenteditable 标记）的那个。
        // 任务清单(TodoDock)/排队(QueueDock) 是它的兄弟节点，不受影响；
        // 提问(QuestionComposer)/权限确认(Approval) 接管 composer 时没有
        // [data-composer-input]，返回 null → 原生条让位，网页接管卡完整可见。
        function nativeInputBar() {
          var field = document.querySelector('[data-composer-input]');
          if (!field) { return null; }
          // 优先：composer stack 的直接子元素里，包含输入框的那一个
          var stacks = document.querySelectorAll('[class*="composerStack"]');
          for (var s = 0; s < stacks.length; s++) {
            var kids = stacks[s].children;
            for (var i = 0; i < kids.length; i++) {
              if (kids[i].contains(field)) { return kids[i]; }
            }
          }
          // 兜底：从输入框往上找"父级是 composerStack"的那一层
          var node = field;
          while (node && node.parentElement) {
            if (String(node.parentElement.className || '').indexOf('composerStack') >= 0) { return node; }
            node = node.parentElement;
          }
          return null;
        }
        // 原生输入条是否应当接管（与 Swift 侧 WebChatShellView.isConversationPage 同源：
        // 有非空会话 id、不在 hero 首屏，且网页确实渲染了输入框）。
        // 返回 true = 原生条接管（隐藏网页那一条输入栏）；false = 网页输入条兜底。
        function syncNativeComposer(id, phase) {
          var root = document.documentElement;
          if (!root || !root.classList) { return false; }
          var bar = nativeInputBar();
          var native = !!id && phase !== 'hero' && !!bar;
          // 先清掉上一轮的标记（React 重渲染会换元素，会话切换也会换输入条）
          var marked = document.querySelectorAll('[data-dsh-native-hide="1"]');
          for (var i = 0; i < marked.length; i++) {
            if (marked[i] !== bar || !native) {
              marked[i].removeAttribute('data-dsh-native-hide');
            }
          }
          if (native && bar) { bar.setAttribute('data-dsh-native-hide', '1'); }
          if (native !== root.classList.contains('dsh-native-composer')) {
            root.classList.toggle('dsh-native-composer', native);
          }
          return native;
        }
        function report() {
          var id = currentSessionId();
          var phase = currentPhase();
          var owns = syncNativeComposer(id, phase);
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
          // 原生输入条是否接管：false 时原生条必须让位（例如正在提问/等权限确认），
          // 否则会把网页的接管卡片挡住，用户无法回答问题。
          if (owns !== lastOwns) {
            lastOwns = owns;
            try {
              window.webkit.messageHandlers.dshComposer.postMessage(owns ? 'native' : 'web');
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

      // ---- 启动（DOM 就绪后执行全部注入）----
      // 注：曾经在 Web 设置页里注入过一个"App 设置"按钮，现已移除——
      // 原生顶栏的齿轮菜单就是唯一的 App 设置入口，网页里不再夹带原生入口。
      whenReady(function () {
        if (window.__dshMobileAdapted) { return; }
        window.__dshMobileAdapted = true;
        try { ensureViewport(); } catch (e) {}
        try { injectStyle(); } catch (e) {}
        startSessionWatch();
      });
    })();
    """
}
