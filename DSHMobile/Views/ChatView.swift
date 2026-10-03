// ============================================================================
//  ChatView.swift — 聊天界面（原生）
//  ----------------------------------------------------------------------------
//  基于 ChatViewModel 的 follow 流渲染：
//    · 用户消息右对齐紫色气泡；助手消息左对齐，支持 text / reasoning（折叠）/ tool-call（胶囊）
//    · 流式输出：增量文本 + 光标动画
//    · 底部输入栏：语音输入（SFSpeechRecognizer）+ 文本 + 发送/取消
//    · 顶部工具栏：当前模式（Agent 预设）/ 模型切换（modelCatalog）/ token 用量 / 停止
//    · 连接状态横幅（已连接/重连中/离线）
// ============================================================================
import SwiftUI

struct ChatView: View {
    let sessionId: String
    /// 从会话列表带进来的摘要（用于初始展示模型/模式/token）
    let summary: SessionSummary?
    @EnvironmentObject var settings: AppSettings
    @StateObject private var vm: ChatViewModel

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    @StateObject private var speech = SpeechRecognizer()
    @State private var showModelPicker = false
    @State private var showModePicker = false
    @State private var showPermissionPicker = false
    @State private var showDocumentPicker = false
    @State private var attachments: [ChatViewModel.PendingAttachment] = []
    @State private var uploadingAttachment = false
    @State private var attachmentError: String?
    @State private var confirmDangerPreset: String?
    // 自动滚动追踪
    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    init(sessionId: String, summary: SessionSummary? = nil) {
        self.sessionId = sessionId
        self.summary = summary
        _vm = StateObject(wrappedValue: ChatViewModel(sessionId: sessionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionBanner
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if vm.messages.isEmpty && vm.connState != .connecting {
                            emptyHint
                        }
                        ForEach(vm.messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: ChatContentHeightKey.self, value: geo.size.height)
                                .preference(key: ChatScrollOffsetKey.self, value: geo.frame(in: .named("chatScroll")).minY)
                        }
                    )
                }
                .coordinateSpace(name: "chatScroll")
                .onPreferenceChange(ChatContentHeightKey.self) { contentHeight = $0 }
                .onPreferenceChange(ChatScrollOffsetKey.self) { scrollOffset = $0 }
                .onChange(of: vm.messages.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: vm.messages.last?.displayText) {
                    scrollToBottom(proxy)
                }
            }
            inputBar
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { viewportHeight = $0 }
            }
        )
        .navigationTitle(vm.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(current: currentModel) { selection in
                Task { await selectModel(selection) }
            }
            .environmentObject(settings)
        }
        .sheet(isPresented: $showModePicker) {
            ModePickerSheet(current: currentMode) { preset in
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
                attachmentError = error.localizedDescription
            }
        }
        .alert("错误", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
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
        .onChange(of: speech.state) { _, newState in
            // 语音停止 → 把最终文本填入输入框
            if newState == .idle, !speech.transcript.isEmpty {
                let text = speech.transcript
                if !inputText.isEmpty { inputText += " " }
                inputText += text
                speech.reset()
            }
        }
        .task {
            vm.start()
        }
        .onDisappear {
            vm.stop()
            speech.reset()
        }
    }

    // MARK: - 当前模型 / 模式

    private var currentModel: ModelSelection? {
        summary?.projectedModelSelection
    }

    private var currentMode: String? {
        summary?.projectedAgentPreset
    }

    @MainActor
    private func selectModel(_ selection: ModelSelection) async {
        let api = APIClient(settings: settings)
        do {
            _ = try await api.selectModel(
                sessionId: sessionId,
                provider: selection.provider,
                model: selection.model,
                reasoningEffort: selection.reasoningEffort
            )
        } catch {
            vm.errorMessage = "切换模型失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func selectMode(_ preset: String) async {
        let api = APIClient(settings: settings)
        do {
            _ = try await api.selectAgentPreset(sessionId: sessionId, agentPreset: preset)
        } catch {
            vm.errorMessage = "切换模式失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 子视图

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // 模式切换
            Button {
                showModePicker = true
            } label: {
                Image(systemName: "sparkles")
            }
            .accessibilityLabel("切换模式")
            // 模型切换
            Button {
                showModelPicker = true
            } label: {
                Image(systemName: "cpu")
            }
            .accessibilityLabel("切换模型")
            // 权限设置
            Button {
                showPermissionPicker = true
            } label: {
                Image(systemName: "checkmark.shield")
            }
            .accessibilityLabel("会话权限")
            // token 用量
            if !vm.tokenSummary.isEmpty {
                Text(vm.tokenSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // 停止生成
            if vm.isStreaming {
                Button {
                    vm.cancel()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .accessibilityLabel("停止生成")
            }
        }
    }

    private var connectionBanner: some View {
        Group {
            switch vm.connState {
            case .offline(let msg):
                Label(msg, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.red)
            case .reconnecting:
                Label("连接断开，正在重连…", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.orange)
            default:
                EmptyView()
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("开始与 DSH 对话吧")
                .foregroundStyle(.secondary)
            if vm.connState == .connecting {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            // 已选附件
            if !attachments.isEmpty {
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
                }
                .padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 10) {
                // 语音输入按钮
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
                .disabled(!vm.canSend)

                TextField("输入消息…", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    .focused($inputFocused)
                    .onSubmit { send() }

                // 添加文件
                Button {
                    if uploadingAttachment {
                        return
                    }
                    showDocumentPicker = true
                } label: {
                    if uploadingAttachment {
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
                .disabled(!vm.canSend || uploadingAttachment)

                // 发送（生成中仍可发送 = 插话）
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSendNow ? .purple : .gray)
                }
                .disabled(!canSendNow)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    /// 是否可发送：文本非空或有附件，且不在提交 RPC 中（生成中允许插话）
    private var canSendNow: Bool {
        (!inputText.trimmed.isEmpty || !attachments.isEmpty) && !vm.isSending
    }

    @MainActor
    private func toggleSpeech() {
        if speech.state == .listening {
            let text = speech.stop()
            if !text.isEmpty {
                if !inputText.isEmpty { inputText += " " }
                inputText += text
            }
            speech.reset()
        } else {
            inputFocused = false
            Task { await speech.start() }
        }
    }

    @MainActor
    private func send() {
        let text = inputText.trimmed
        let atts = attachments
        guard !text.isEmpty || !atts.isEmpty else { return }
        vm.send(text, attachments: atts)
        inputText = ""
        attachments = []
    }

    /// 选择文件 → 读取并上传，成功后追加到附件列表
    @MainActor
    private func attachFile(from url: URL) {
        guard !uploadingAttachment else { return }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            attachmentError = "无法读取文件 \(name)"
            return
        }
        uploadingAttachment = true
        Task {
            let api = APIClient(settings: settings)
            do {
                let result = try await api.uploadFile(sessionId: sessionId, name: name, data: data)
                attachments.append(ChatViewModel.PendingAttachment(receiptId: result.receiptId, name: name))
            } catch {
                attachmentError = "上传失败：\(error.localizedDescription)"
            }
            uploadingAttachment = false
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
        let api = APIClient(settings: settings)
        do {
            let result = try await api.runCommand(sessionId: sessionId, line: "/permission \(preset)")
            if result.result?.kind != "success" {
                vm.errorMessage = result.result?.text ?? "切换权限失败：未知错误"
            }
        } catch {
            vm.errorMessage = "切换权限失败：\(error.localizedDescription)"
        }
    }

    /// 自动滚动：新消息总是跟随；流式增量仅在接近底部时跟随，且不带动画
    @MainActor
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = vm.messages.last else { return }
        if vm.isStreaming && !isNearBottom {
            return
        }
        if vm.isStreaming {
            proxy.scrollTo(last.id, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// 是否接近底部（内容底与视口底差距 < 100pt）
    private var isNearBottom: Bool {
        guard contentHeight > 0, viewportHeight > 0 else { return true }
        return contentHeight - viewportHeight + scrollOffset < 100
    }
}

// MARK: - 滚动位置偏好

private struct ChatContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 消息气泡

struct MessageBubble: View {
    let message: ChatMessage
    @State private var reasoningExpanded = false

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if message.role == .user {
                    userContent
                } else {
                    assistantContent
                }
            }
            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
        .onChange(of: message.isStreaming) { _, streaming in
            // 流式期间自动展开思考过程
            if streaming {
                reasoningExpanded = true
            }
        }
    }

    /// 用户消息：文件块以胶囊展示，文本块正常展示
    @ViewBuilder
    private var userContent: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if message.blocks.isEmpty {
                Text(message.summary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.purple, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white)
            } else {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    userBlockView(block)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.purple, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private func userBlockView(_ block: ChatMessage.Block) -> some View {
        switch block {
        case .file(let name, let bytes):
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                Text(name)
                    .font(.caption.bold())
                    .lineLimit(1)
                if bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption2)
                        .opacity(0.8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.2), in: Capsule())
        case .text(let t):
            if !t.isEmpty {
                Text(t)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .reasoning(let r):
            if !r.isEmpty {
                Text("思考：\(r)")
                    .font(.footnote)
                    .opacity(0.9)
                    .textSelection(.enabled)
            }
        case .toolCall(let id, let name, _):
            Text("[工具] \(name.isEmpty ? "工具调用" : name)")
                .font(.caption)
                .opacity(0.9)
                .accessibilityLabel("工具调用 \(name) \(id)")
        case .other:
            EmptyView()
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.isStreaming && message.blocks.isEmpty {
                typingIndicator
            } else {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            // 流式尾巴光标
            if message.isStreaming {
                HStack(spacing: 2) {
                    Text("▍")
                        .foregroundStyle(.purple)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func blockView(_ block: ChatMessage.Block) -> some View {
        switch block {
        case .text(let t):
            if !t.isEmpty {
                Text(t)
                    .textSelection(.enabled)
            }
        case .reasoning(let r):
            if !r.isEmpty {
                DisclosureGroup(isExpanded: $reasoningExpanded) {
                    Text(r)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("思考过程", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .toolCall(let id, let name, _):
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
                Text(name.isEmpty ? "工具调用" : name)
                    .font(.caption.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.purple.opacity(0.15), in: Capsule())
            .accessibilityLabel("工具调用 \(name) \(id)")
        case .file(let name, let bytes):
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .font(.caption)
                Text(name)
                    .font(.caption.bold())
                    .lineLimit(1)
                if bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.purple.opacity(0.12), in: Capsule())
        case .other:
            EmptyView()
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(0.6)
            }
        }
    }
}

// MARK: - 模式选择（Agent 预设）

struct ModePickerSheet: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let current: String?
    let onSelect: (String) -> Void

    @State private var presets: [AgentPresetRow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载模式…")
                } else if let errorMessage {
                    ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else {
                    List {
                        Section("模式（Agent 预设）") {
                            ForEach(presets) { preset in
                                Button {
                                    onSelect(preset.id)
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(preset.name ?? preset.id)
                                                .foregroundStyle(.primary)
                                            if let desc = preset.description, !desc.isEmpty {
                                                Text(desc)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                        if preset.id == current {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.purple)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("切换模式")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func load() async {
        let api = APIClient(settings: settings)
        isLoading = true
        defer { isLoading = false }
        do {
            let roster = try await api.agentPresetsList()
            presets = roster.presets.sorted { a, b in
                if a.isDefault == true { return true }
                if b.isDefault == true { return false }
                return (a.order ?? 999) < (b.order ?? 999)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 模型选择（modelCatalog）

struct ModelPickerSheet: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let current: ModelSelection?
    let onSelect: (ModelSelection) -> Void

    @State private var catalog: ModelCatalog?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载模型…")
                } else if let errorMessage {
                    ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if let catalog {
                    List {
                        ForEach(catalog.groups) { group in
                            Section(group.name ?? group.id) {
                                ForEach(group.models) { model in
                                    modelRow(model, group: group)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("切换模型")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func modelRow(_ model: ModelCatalogModel, group: ModelProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                // 推理模型带 effort 选择；非推理模型直接用默认
                if let reasoning = model.reasoning {
                    let effort = reasoning.defaultEffort ?? reasoning.efforts.first?.id
                    onSelect(ModelSelection(provider: group.id, model: model.id, reasoningEffort: effort))
                } else {
                    onSelect(ModelSelection(provider: group.id, model: model.id, reasoningEffort: nil))
                }
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name ?? model.id)
                            .foregroundStyle(.primary)
                        if let desc = model.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let reasoning = model.reasoning, !reasoning.efforts.isEmpty {
                            Text("推理强度：\(reasoning.efforts.map { $0.name ?? $0.id }.joined(separator: " / "))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if current?.provider == group.id && current?.model == model.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.purple)
                    }
                }
            }
        }
    }

    @MainActor
    private func load() async {
        let api = APIClient(settings: settings)
        isLoading = true
        defer { isLoading = false }
        do {
            catalog = try await api.modelCatalog()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 会话权限选择（permissionPresets/catalog + /permission 命令）

struct PermissionPickerSheet: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let current: String?
    let onSelect: (String) -> Void

    @State private var catalog: PermissionCatalog?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载权限…")
                } else if let errorMessage {
                    ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if let catalog {
                    List {
                        Section {
                            ForEach(catalog.options) { option in
                                Button {
                                    onSelect(option.value)
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.name ?? option.value)
                                                .foregroundStyle(.primary)
                                            if let desc = option.description, !desc.isEmpty {
                                                Text(desc)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                        if option.value == current {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.purple)
                                        }
                                    }
                                }
                            }
                        } footer: {
                            if let def = catalog.defaultPreset {
                                Text("默认权限预设：\(def)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("会话权限")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func load() async {
        let api = APIClient(settings: settings)
        isLoading = true
        defer { isLoading = false }
        do {
            catalog = try await api.permissionPresetsCatalog()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 工具

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
