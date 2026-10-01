// ============================================================================
//  ChatView.swift — 聊天界面
//  ----------------------------------------------------------------------------
//  基于 ChatViewModel 的 follow 流渲染：
//    · 用户消息右对齐紫色气泡
//    · 助手消息左对齐深色气泡，支持 text / reasoning（折叠）/ tool-call（胶囊）
//    · 流式输出：增量文本 + 光标动画
//    · 底部输入栏 + 发送/取消
//    · 顶部显示连接状态（已连接/重连中/离线）
// ============================================================================
import SwiftUI

struct ChatView: View {
    let sessionId: String
    @EnvironmentObject var settings: AppSettings
    @StateObject private var vm: ChatViewModel

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    init(sessionId: String) {
        self.sessionId = sessionId
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
                }
                .onChange(of: vm.messages.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: vm.messages.last?.displayText) {
                    scrollToBottom(proxy)
                }
            }
            inputBar
        }
        .navigationTitle(vm.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
        .alert("错误", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .task {
            vm.start()
        }
        .onDisappear {
            vm.stop()
        }
    }

    // MARK: - 子视图

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
        HStack(alignment: .bottom, spacing: 10) {
            TextField("输入消息…", text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                .focused($inputFocused)
                .onSubmit { send() }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(inputText.trimmed.isEmpty ? .gray : .purple)
            }
            .disabled(inputText.trimmed.isEmpty || !vm.canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @MainActor
    private func send() {
        let text = inputText.trimmed
        guard !text.isEmpty else { return }
        vm.send(text)
        inputText = ""
    }

    @MainActor
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = vm.messages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

// MARK: - 消息气泡

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if message.role == .user {
                    Text(message.summary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.purple, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                } else {
                    assistantContent
                }
            }
            if message.role == .assistant {
                Spacer(minLength: 48)
            }
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
                DisclosureGroup {
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

// MARK: - 工具

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
