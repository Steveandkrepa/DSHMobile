// ============================================================================
//  WebChatShellView.swift — 主界面外壳（网页承载对话流 + 原生按键）
//
//  用户诉求（m05937）："对话流应该用网页，只是按键都用原生的"。
//  因此主界面 = 官方网页控制台承载会话列表 / 对话流 / 仪表盘，
//  原生只补两类按键：
//    1) 顶栏：会话标题 + 运行指示 + 模式 / 模型 / 权限 / 设置
//    2) 输入条：文本 / 语音 / 附件 / 发送（生成中 = 插话）/ 停止
//
//  布局 = 光斑背景上的三段 VStack（顶栏 / 网页 / 输入条），网页视图被自动压到中间，
//  因此不需要任何 CSS 高度补偿；顶栏与输入条是四边留边的悬浮玻璃岛，
//  能采到背后的光斑（不依赖 iOS 26 的 glassEffect，iOS 17 同样呈现）。
//  输入条只在「网页确实渲染着官方输入框」时显示（见 isConversationPage）：
//  网页 hero 首屏、以及网页把 composer 让给提问卡/权限确认时，原生条自动让位。
//
//  与网页的状态同步链：
//    - 会话 id：WebConsoleView 内 JS 读 [data-conversation-session]
//               → messageHandler dshSession → settings.activeWebSessionId
//    - 页面阶段：JS 读 [data-phase] / [data-content-phase]
//               → messageHandler dshPhase → settings.webConversationPhase
//    - 运行中 / 标题：SessionWatcher 轮询 session/list，按 activeWebSessionId 取摘要
// ============================================================================

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct WebChatShellView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    /// 全局会话观察者：提供当前网页会话的摘要与「是否生成中」
    @ObservedObject private var watcher = SessionWatcher.shared

    /// 网页协调器由外壳持有：这样顶栏/抽屉可以在网页里程序化切换会话
    @State private var webCoordinator = Coordinator()

    @State private var showModePicker = false
    @State private var showModelPicker = false
    @State private var showPermissionPicker = false
    @State private var showAppSettings = false
    @State private var showSessionDrawer = false
    @State private var confirmDangerPreset: String?
    @State private var errorMessage: String?
    /// 每 +1 请求一次网页彻底刷新（WebConsoleView 监听它并重新探测基址 + 回到 /pair-app）
    @State private var reloadNonce = 0

    private var sessionId: String? {
        settings.activeWebSessionId
    }

    private var summary: SessionSummary? {
        watcher.activeSummary
    }

    private var title: String {
        if let t = summary?.projectedTitle, !t.isEmpty { return t }
        return "DSH"
    }

    /// 是否显示原生输入条。
    /// 三个条件缺一不可：
    ///  1. 已打开会话（sessionId != nil）
    ///  2. 不在网页 hero 首屏（hero 保留网页输入框，避免两条输入栏叠加）
    ///  3. 网页没有把 composer 区域让给「提问卡 / 权限确认」等接管视图
    ///     （nativeComposerActive 由 JS 实测网页输入框仍在 DOM 里才会为 true）
    /// 第 3 条是「提问回答功能必须保留」的关键：网页在等用户回答时，原生条让位，
    /// 用户看到的是网页的提问卡，可以直接点选/输入答案。
    private var isConversationPage: Bool {
        sessionId != nil
            && settings.webConversationPhase != "hero"
            && settings.nativeComposerActive
    }

    /// 请求网页彻底刷新（重新探测基址 + 重注入 cookie 后回到 /pair-app 入口）。
    /// 不能直接 webView.reload()：/pair-app 会把地址栏改写成 /，而局域网上的 /
    /// 是配对页，直接重载会显示「未配对」。
    private func requestWebReload() {
        reloadNonce += 1
    }

    var body: some View {
        // 光斑背景 + 悬浮玻璃顶栏/输入条：顶栏与输入条四周留边，
        // 玻璃能采到底下的彩色光斑，才有"液态玻璃"的折射感。
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                topBar
                // 网页控制台：不忽略安全区，顶/底原生栏各占一条安全区
                WebConsoleView(fillSafeArea: false, coordinator: webCoordinator, reloadRequest: reloadNonce)
                if isConversationPage {
                    NativeComposerBar(
                        sessionId: sessionId,
                        isRunning: watcher.activeIsRunning,
                        onError: { errorMessage = $0 },
                        onActivity: { watcher.refreshNow() }
                    )
                }
            }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(current: summary?.projectedModelSelection) { selection in
                Task { await selectModel(selection) }
            }
            .environmentObject(settings)
        }
        .sheet(isPresented: $showModePicker) {
            ModePickerSheet(current: summary?.projectedAgentPreset) { preset in
                Task { await selectMode(preset) }
            }
            .environmentObject(settings)
        }
        .sheet(isPresented: $showPermissionPicker) {
            PermissionPickerSheet(current: summary?.projectedPermission) { preset in
                Task { await selectPermission(preset) }
            }
            .environmentObject(settings)
        }
        .sheet(isPresented: $showAppSettings) {
            NavigationStack {
                AppSettingsView()
                    .environmentObject(settings)
            }
        }
        .sheet(isPresented: $showSessionDrawer) {
            SessionDrawer(
                currentSessionId: sessionId,
                onOpen: { id in webCoordinator.openSession(id) },
                onNewSession: { webCoordinator.newSession() },
                onOpenSettings: {
                    // 先收起抽屉再打开设置：同一层 sheet 不能同时压两个
                    showSessionDrawer = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showAppSettings = true
                    }
                },
                onReload: { requestWebReload() },
                onClose: { showSessionDrawer = false }
            )
            .environmentObject(settings)
        }
        .task {
            // 原生发起的网页导航回执（打开会话 / 新建会话）
            webCoordinator.onNavResult = { result in
                Task { @MainActor in
                    switch result {
                    case "open-failed":
                        errorMessage = "没能在网页里打开这个会话。请下拉刷新网页后重试，或直接在网页里选择。"
                    case "create-failed":
                        errorMessage = "没能在网页里新建会话。请下拉刷新网页后重试。"
                    case "opened", "created":
                        watcher.refreshNow()
                    default:
                        break
                    }
                }
            }
            watcher.refreshNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationRouter.openSession)) { note in
            // 点击「完成/失败/提问」通知：直接在网页里打开对应会话
            if let id = note.userInfo?["sessionId"] as? String, !id.isEmpty {
                webCoordinator.openSession(id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // 回到前台：刷新会话摘要（标题/运行状态），网页自身也会重连
            if phase == .active { watcher.refreshNow() }
        }
        .alert("错误", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("权限变更确认", isPresented: Binding(
            get: { confirmDangerPreset != nil },
            set: { if !$0 { confirmDangerPreset = nil } }
        )) {
            Button("取消", role: .cancel) { confirmDangerPreset = nil }
            Button("确认切换", role: .destructive) {
                let preset = confirmDangerPreset
                confirmDangerPreset = nil
                if let preset { Task { await applyPermission(preset) } }
            }
        } message: {
            Text("切换为「完整权限（danger-full-access）」后，助手将可以读写文件系统并执行任意命令，请确认。")
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { showSessionDrawer = true } label: {
                Image(systemName: "sidebar.left").dsGlassIcon()
            }
            .accessibilityLabel("会话列表")

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 2)

            if watcher.activeIsRunning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.purple)
            }

            Button { showModePicker = true } label: {
                Image(systemName: "sparkles").dsGlassIcon()
            }
            .disabled(sessionId == nil)
            .opacity(sessionId == nil ? 0.45 : 1)
            .accessibilityLabel("切换模式")

            Button { showModelPicker = true } label: {
                Image(systemName: "cpu").dsGlassIcon()
            }
            .disabled(sessionId == nil)
            .opacity(sessionId == nil ? 0.45 : 1)
            .accessibilityLabel("切换模型")

            Button { showPermissionPicker = true } label: {
                Image(systemName: "checkmark.shield").dsGlassIcon()
            }
            .disabled(sessionId == nil)
            .opacity(sessionId == nil ? 0.45 : 1)
            .accessibilityLabel("会话权限")

            Button { webCoordinator.newSession() } label: {
                Image(systemName: "square.and.pencil").dsGlassIcon()
            }
            .accessibilityLabel("新建会话")

            Menu {
                Button {
                    showAppSettings = true
                } label: {
                    Label("App 设置", systemImage: "gearshape")
                }
                Button {
                    requestWebReload()
                } label: {
                    Label("重新加载网页", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "gearshape").dsGlassIcon()
            }
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .dsGlassPanel()
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: - 模式 / 模型 / 权限

    @MainActor
    private func selectModel(_ selection: ModelSelection) async {
        guard let sessionId else { return }
        let api = APIClient(settings: settings)
        do {
            _ = try await api.selectModel(
                sessionId: sessionId,
                provider: selection.provider,
                model: selection.model,
                reasoningEffort: selection.reasoningEffort
            )
        } catch {
            errorMessage = "切换模型失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func selectMode(_ preset: String) async {
        guard let sessionId else { return }
        let api = APIClient(settings: settings)
        do {
            _ = try await api.selectAgentPreset(sessionId: sessionId, agentPreset: preset)
        } catch {
            errorMessage = "切换模式失败：\(error.localizedDescription)"
        }
    }

    /// 权限选择：危险预设先确认，其余直接应用
    @MainActor
    private func selectPermission(_ preset: String) {
        if preset == "danger-full-access" {
            confirmDangerPreset = preset
        } else {
            Task { await applyPermission(preset) }
        }
    }

    /// 通过 /permission 命令写入会话权限预设
    @MainActor
    private func applyPermission(_ preset: String) async {
        guard let sessionId else { return }
        let api = APIClient(settings: settings)
        do {
            let result = try await api.runCommand(sessionId: sessionId, line: "/permission \(preset)")
            if result.result?.kind != "success" {
                errorMessage = result.result?.text ?? "切换权限失败：未知错误"
            }
        } catch {
            errorMessage = "切换权限失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 原生输入条

/// 原生输入条：文本 / 语音 / 附件 / 发送（生成中 = 插话）/ 停止。
/// 只负责把消息交给服务端，渲染仍由网页视图的会话流完成。
private struct NativeComposerBar: View {
    @EnvironmentObject var settings: AppSettings

    let sessionId: String?
    /// 当前会话是否生成中（决定发送语义：queue 还是 steer）
    let isRunning: Bool
    let onError: (String) -> Void
    /// 发送/停止成功后回调，让观察者立刻刷新运行状态
    let onActivity: () -> Void

    struct ShellAttachment: Identifiable, Equatable {
        let receiptId: String
        let name: String
        var id: String { receiptId }
    }

    @State private var inputText = ""
    @State private var attachments: [ShellAttachment] = []
    @State private var uploading = false
    @State private var isSending = false
    @State private var showDocumentPicker = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCommandPicker = false
    /// 命令执行结果（横幅展示，几秒后自动消失）
    @State private var commandOutput: String?
    /// 生成中发送消息的方式："queue"=排队（不打断当前生成）/ "steer"=立刻插话
    @State private var sendMode = "queue"
    @StateObject private var speech = SpeechRecognizer()
    @FocusState private var inputFocused: Bool

    private var trimmed: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 可发送：有会话、有内容、且不在提交 RPC 中（生成中允许插话）
    private var canSend: Bool {
        sessionId != nil && (!trimmed.isEmpty || !attachments.isEmpty) && !isSending
    }

    var body: some View {
        VStack(spacing: 6) {
            if let commandOutput {
                commandBanner(commandOutput)
            }
            if !attachments.isEmpty {
                attachmentChips
            }
            // 生成中：让用户自己决定这条消息是排队等还是立刻插话打断
            if isRunning {
                HStack(spacing: 6) {
                    sendModeChip("排队", value: "queue", icon: "clock")
                    sendModeChip("马上插话", value: "steer", icon: "bolt.fill")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }
            HStack(alignment: .bottom, spacing: 6) {
                Button {
                    showCommandPicker = true
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 18))
                        .foregroundStyle(.purple)
                        .frame(width: 30, height: 36)
                }
                .accessibilityLabel("命令")
                .disabled(sessionId == nil)

                Button {
                    if !uploading { showDocumentPicker = true }
                } label: {
                    if uploading {
                        ProgressView()
                            .frame(width: 30, height: 36)
                    } else {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18))
                            .foregroundStyle(.purple)
                            .frame(width: 30, height: 36)
                    }
                }
                .accessibilityLabel("添加文件")
                .disabled(sessionId == nil || uploading)

                Button {
                    if !uploading { showPhotoPicker = true }
                } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.purple)
                        .frame(width: 30, height: 36)
                }
                .accessibilityLabel("添加照片")
                .disabled(sessionId == nil || uploading)

                Button {
                    toggleSpeech()
                } label: {
                    Image(systemName: speech.state == .listening ? "mic.fill" : "mic")
                        .font(.system(size: 18))
                        .foregroundStyle(speech.state == .listening ? .white : .purple)
                        .frame(width: 30, height: 36)
                        .background(speech.state == .listening ? Color.purple : Color.clear, in: Circle())
                }
                .accessibilityLabel(speech.state == .listening ? "停止语音输入" : "语音输入")
                .disabled(sessionId == nil)

                TextField("输入消息…", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
                    )
                    .focused($inputFocused)
                    .disabled(sessionId == nil)
                    .onSubmit { send() }

                if isRunning {
                    Button {
                        stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("停止生成")
                }

                // 发送：生成中按上面的选择 = 排队（queue）或马上插话（steer）
                Button {
                    send()
                } label: {
                    Image(systemName: isRunning ? (sendMode == "steer" ? "bolt.circle.fill" : "clock.circle.fill") : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? .purple : .gray)
                }
                .accessibilityLabel(isRunning ? (sendMode == "steer" ? "马上插话" : "排队发送") : "发送")
                .disabled(!canSend)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        // 悬浮玻璃输入条：四周留边，露出底下的光斑
        .dsGlassPanel(corner: 24, tint: .purple)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .fileImporter(
            isPresented: $showDocumentPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                attachFile(from: url)
            case .failure(let error):
                onError(error.localizedDescription)
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItem,
            matching: .images
        )
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                defer { photoItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    onError("无法读取所选照片")
                    return
                }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                await upload(data: data, name: "photo-\(Self.timestamp()).\(ext)")
            }
        }
        .sheet(isPresented: $showCommandPicker) {
            if let sessionId {
                CommandPickerSheet(sessionId: sessionId) { command in
                    pick(command)
                }
                .environmentObject(settings)
            }
        }
        .onChange(of: speech.state) { _, newState in
            // 语音停止 → 把最终文本填入输入框
            if newState == .idle, !speech.transcript.isEmpty {
                appendSpeech(speech.transcript)
                speech.reset()
            }
        }
    }

    /// 生成中的发送方式选择（排队 / 马上插话）
    private func sendModeChip(_ title: String, value: String, icon: String) -> some View {
        let selected = sendMode == value
        return Button {
            sendMode = value
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.caption.weight(selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Color.white : Color.purple)
            .dsGlassCapsule(active: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == "steer" ? "生成中发送为马上插话" : "生成中发送为排队")
    }

    /// 命令执行结果横幅（网页斜杠命令在原生输入条里的等价物）
    private func commandBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.caption2)
                .foregroundStyle(.purple)
            Text(text)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                commandOutput = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("关闭命令结果")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.purple.opacity(0.12))
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                        Text(att.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.purple.opacity(0.15), in: Capsule())
                    .overlay(alignment: .topTrailing) {
                        Button {
                            attachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 发送 / 停止

    /// 发送："/" 开头走命令执行（commands/execute，与网页斜杠命令同源），
    /// 其余走会话消息；生成中发新消息 = 插话（mode=steer），空闲 = queue
    @MainActor
    private func send() {
        guard let sessionId else { return }
        let text = trimmed
        let atts = attachments
        guard !text.isEmpty || !atts.isEmpty else { return }
        let mode = isRunning ? sendMode : "queue"
        let isCommand = text.hasPrefix("/")
        inputText = ""
        attachments = []
        isSending = true
        Task {
            let api = APIClient(settings: settings)
            do {
                if isCommand {
                    let result = try await api.runCommand(sessionId: sessionId, line: text)
                    if result.result?.kind == "error" {
                        onError(result.result?.text ?? "命令执行失败")
                    } else if let output = result.result?.text, !output.isEmpty {
                        showCommandOutput(output)
                    }
                } else {
                    let result = try await api.prompt(
                        sessionId: sessionId,
                        text: text,
                        mode: mode,
                        attachments: atts.map(\.receiptId)
                    )
                    if !result.accepted {
                        throw NSError(
                            domain: "DSHMobile",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "服务器没有接受这条消息，请稍后重试。"]
                        )
                    }
                }
            } catch {
                // 失败回填，避免用户输入丢失
                if inputText.isEmpty { inputText = text }
                if attachments.isEmpty { attachments = atts }
                onError(isCommand ? "命令执行失败：\(error.localizedDescription)" : "发送失败：\(error.localizedDescription)")
            }
            isSending = false
            onActivity()
        }
    }

    /// 选中命令：需要参数的插入输入框（保留补充参数的机会），无需参数的立即执行
    @MainActor
    private func pick(_ command: APIClient.CommandInfo) {
        if command.input == nil {
            inputText = "/" + command.name
            send()
        } else {
            inputText = "/" + command.name + " "
            inputFocused = true
        }
    }

    /// 命令结果横幅：6 秒后自动消失
    @MainActor
    private func showCommandOutput(_ text: String) {
        commandOutput = text
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if commandOutput == text { commandOutput = nil }
        }
    }

    @MainActor
    private func stop() {
        guard let sessionId else { return }
        Task {
            let api = APIClient(settings: settings)
            do {
                _ = try await api.cancelSession(sessionId: sessionId)
            } catch {
                onError("停止失败：\(error.localizedDescription)")
            }
            onActivity()
        }
    }

    // MARK: - 附件

    /// 选择文件 → 读取并上传，成功后追加到附件列表
    @MainActor
    private func attachFile(from url: URL) {
        guard !uploading else { return }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            onError("无法读取文件 \(name)")
            return
        }
        Task { await upload(data: data, name: name) }
    }

    /// 上传附件（文件 / 照片共用）：成功后追加到附件列表，随下一条消息发送
    @MainActor
    private func upload(data: Data, name: String) async {
        guard let sessionId else { return }
        uploading = true
        defer { uploading = false }
        let api = APIClient(settings: settings)
        do {
            let result = try await api.uploadFile(sessionId: sessionId, name: name, data: data)
            attachments.append(ShellAttachment(receiptId: result.receiptId, name: name))
        } catch {
            onError("上传失败：\(error.localizedDescription)")
        }
    }

    /// 照片文件名用的时间戳
    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - 语音

    @MainActor
    private func toggleSpeech() {
        if speech.state == .listening {
            let text = speech.stop()
            if !text.isEmpty { appendSpeech(text) }
            speech.reset()
        } else {
            inputFocused = false
            Task { await speech.start() }
        }
    }

    @MainActor
    private func appendSpeech(_ text: String) {
        guard !text.isEmpty else { return }
        if !inputText.isEmpty { inputText += " " }
        inputText += text
    }
}

// ============================================================================
//  命令面板：原生输入条补上网页的斜杠命令能力
//  网页 composer 被隐藏后，用户输入 "/xxx" 若直接走 session/prompt 会被当成
//  普通消息；这里从 commands/list 取会话可用命令，选中后由输入条改用
//  commands/execute 执行（与网页斜杠命令同一个服务端入口）。
// ============================================================================

private struct CommandPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: AppSettings

    let sessionId: String
    let onPick: (APIClient.CommandInfo) -> Void

    @State private var commands: [APIClient.CommandInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("正在读取命令…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if commands.isEmpty {
                    Text("这个会话没有可用命令。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(commands) { command in
                            Button {
                                onPick(command)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("/" + command.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.purple)
                                    Text(command.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let hint = command.input?.hint, !hint.isEmpty {
                                        Text(hint)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("与网页里的斜杠命令一致；需要参数的命令会先填入输入框，补全后再发送。")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("命令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do {
            commands = try await APIClient(settings: settings).listCommands(sessionId: sessionId)
            errorMessage = nil
        } catch {
            errorMessage = "读取命令失败：\(error.localizedDescription)"
        }
        isLoading = false
    }
}
