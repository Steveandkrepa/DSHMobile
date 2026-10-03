// ============================================================================
//  WebChatShellView.swift — 主界面外壳（网页承载对话流 + 原生按键）
//
//  用户诉求（m05937）："对话流应该用网页，只是按键都用原生的"。
//  因此主界面 = 官方网页控制台承载会话列表 / 对话流 / 仪表盘，
//  原生只补两类按键：
//    1) 顶栏：会话标题 + 运行指示 + 模式 / 模型 / 权限 / 设置
//    2) 输入条：文本 / 语音 / 附件 / 发送（生成中 = 插话）/ 停止
//
//  布局用真实的三段 VStack（顶栏 / 网页 / 输入条），网页视图被自动压到中间，
//  因此不需要任何 CSS 高度补偿；输入条只在网页处于「会话页」(active/settling)
//  时显示 —— 网页 hero 首屏保留它自带的输入框，用于新建会话。
//
//  与网页的状态同步链：
//    - 会话 id：WebConsoleView 内 JS 读 [data-conversation-session]
//               → messageHandler dshSession → settings.activeWebSessionId
//    - 页面阶段：JS 读 [data-phase] / [data-content-phase]
//               → messageHandler dshPhase → settings.webConversationPhase
//    - 运行中 / 标题：SessionWatcher 轮询 session/list，按 activeWebSessionId 取摘要
// ============================================================================

import SwiftUI
import UniformTypeIdentifiers

struct WebChatShellView: View {
    @EnvironmentObject var settings: AppSettings

    /// 全局会话观察者：提供当前网页会话的摘要与「是否生成中」
    @ObservedObject private var watcher = SessionWatcher.shared

    @State private var showModePicker = false
    @State private var showModelPicker = false
    @State private var showPermissionPicker = false
    @State private var showAppSettings = false
    @State private var confirmDangerPreset: String?
    @State private var errorMessage: String?

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

    /// 是否显示原生输入条：已打开会话，且不在网页 hero 首屏
    /// （hero = 新建/空白会话首屏，那里保留网页自带输入框，避免两条输入栏叠在一起）。
    /// 用「会话 id 存在」做主判据、「phase != hero」做排除，这样即使网页阶段值
    /// 意外缺失（拿到未知值）也仍然给得出输入条，不会把用户卡在无法输入的状态。
    private var isConversationPage: Bool {
        sessionId != nil && settings.webConversationPhase != "hero"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            // 网页控制台：不忽略安全区，顶/底原生栏各占一条安全区
            WebConsoleView(fillSafeArea: false)
            if isConversationPage {
                NativeComposerBar(
                    sessionId: sessionId,
                    isRunning: watcher.activeIsRunning,
                    onError: { errorMessage = $0 },
                    onActivity: { watcher.refreshNow() }
                )
            }
        }
        .background(Color.black.ignoresSafeArea())
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
        HStack(spacing: 16) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if watcher.activeIsRunning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.purple)
            }

            Button { showModePicker = true } label: {
                Image(systemName: "sparkles")
            }
            .disabled(sessionId == nil)
            .accessibilityLabel("切换模式")

            Button { showModelPicker = true } label: {
                Image(systemName: "cpu")
            }
            .disabled(sessionId == nil)
            .accessibilityLabel("切换模型")

            Button { showPermissionPicker = true } label: {
                Image(systemName: "checkmark.shield")
            }
            .disabled(sessionId == nil)
            .accessibilityLabel("会话权限")

            Button { showAppSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("设置")
        }
        .font(.system(size: 17))
        .foregroundStyle(.purple)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
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
            if !attachments.isEmpty {
                attachmentChips
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    if !uploading { showDocumentPicker = true }
                } label: {
                    if uploading {
                        ProgressView()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20))
                            .foregroundStyle(.purple)
                            .frame(width: 36, height: 36)
                    }
                }
                .accessibilityLabel("添加文件")
                .disabled(sessionId == nil || uploading)

                Button {
                    toggleSpeech()
                } label: {
                    Image(systemName: speech.state == .listening ? "mic.fill" : "mic")
                        .font(.system(size: 20))
                        .foregroundStyle(speech.state == .listening ? .white : .purple)
                        .frame(width: 36, height: 36)
                        .background(speech.state == .listening ? Color.purple : Color.clear, in: Circle())
                }
                .accessibilityLabel(speech.state == .listening ? "停止语音输入" : "语音输入")
                .disabled(sessionId == nil)

                TextField("输入消息…", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
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

                // 发送：生成中 = 插话（mode=steer）
                Button {
                    send()
                } label: {
                    Image(systemName: isRunning ? "bolt.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? .purple : .gray)
                }
                .accessibilityLabel(isRunning ? "插话" : "发送")
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
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
        .onChange(of: speech.state) { _, newState in
            // 语音停止 → 把最终文本填入输入框
            if newState == .idle, !speech.transcript.isEmpty {
                appendSpeech(speech.transcript)
                speech.reset()
            }
        }
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

    /// 发送：生成中发新消息 = 插话（mode=steer），空闲 = queue
    @MainActor
    private func send() {
        guard let sessionId else { return }
        let text = trimmed
        let atts = attachments
        guard !text.isEmpty || !atts.isEmpty else { return }
        let mode = isRunning ? "steer" : "queue"
        inputText = ""
        attachments = []
        isSending = true
        Task {
            let api = APIClient(settings: settings)
            do {
                _ = try await api.prompt(
                    sessionId: sessionId,
                    text: text,
                    mode: mode,
                    attachments: atts.map(\.receiptId)
                )
            } catch {
                // 失败回填，避免用户输入丢失
                if inputText.isEmpty { inputText = text }
                if attachments.isEmpty { attachments = atts }
                onError("发送失败：\(error.localizedDescription)")
            }
            isSending = false
            onActivity()
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
        guard let sessionId, !uploading else { return }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            onError("无法读取文件 \(name)")
            return
        }
        uploading = true
        Task {
            let api = APIClient(settings: settings)
            do {
                let result = try await api.uploadFile(sessionId: sessionId, name: name, data: data)
                attachments.append(ShellAttachment(receiptId: result.receiptId, name: name))
            } catch {
                onError("上传失败：\(error.localizedDescription)")
            }
            uploading = false
        }
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
