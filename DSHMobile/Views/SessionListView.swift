// ============================================================================
//  SessionListView.swift — 会话列表（原生主界面根视图）
//  ----------------------------------------------------------------------------
//  拉取 session.list（HTTP RPC），展示历史会话：
//    · 每行显示标题 / 时间·工作目录 / 运行状态 / 累计 token 用量 / 权限徽标
//    · 新建会话（可选 Agent 预设模式，含「梁神模式」等自定义预设）
//    · 左滑/长按设置「特别关注」（watch level）
//    · 长按菜单：重命名 / 派生（fork）
//    · 右上角：完整 Web 界面兜底 + 原生 App 设置
//    · 通知点击（NotificationRouter.openSession）直达对应会话
// ============================================================================
import SwiftUI
import UIKit

struct SessionListView: View {
    @EnvironmentObject var settings: AppSettings

    @State private var sessions: [SessionSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var showWebConsole = false
    @State private var hasLoaded = false
    /// 新建会话的预设选择弹窗
    @State private var showCreateSheet = false
    /// 通知点击 → 要打开的会话（fullScreenCover 呈现，避免与导航栈冲突）
    @State private var notificationSession: NotificationSession?

    var body: some View {
        Group {
            if isLoading && sessions.isEmpty {
                ProgressView("加载会话…")
            } else if sessions.isEmpty && !hasLoaded {
                ContentUnavailableView(
                    "连不上服务器",
                    systemImage: "wifi.slash",
                    description: Text(errorMessage ?? "请检查地址或配对状态")
                )
            } else {
                sessionList
            }
        }
        .navigationTitle("会话")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                AppSettingsView()
                    .environmentObject(settings)
            }
        }
        .sheet(isPresented: $showWebConsole) {
            NavigationStack {
                WebConsoleView()
                    .environmentObject(settings)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateSessionSheet { agentPreset in
                Task { await createSession(agentPreset: agentPreset) }
            }
            .environmentObject(settings)
        }
        .fullScreenCover(item: $notificationSession) { target in
            NavigationStack {
                ChatView(sessionId: target.sessionId)
                    .environmentObject(settings)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭") { notificationSession = nil }
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationRouter.openSession)) { note in
            if let sid = note.userInfo?["sessionId"] as? String {
                notificationSession = NotificationSession(sessionId: sid)
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("复制详情") {
                UIPasteboard.general.string = errorMessage ?? ""
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var sessionList: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "还没有会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("点右上角 + 新建一个会话")
                )
            } else {
                ForEach(sessions) { session in
                    NavigationLink {
                        ChatView(sessionId: session.sessionId, summary: session)
                    } label: {
                        SessionRow(session: session)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        ForEach(WatchLevel.allCases, id: \.self) { level in
                            Button {
                                settings.setWatchLevel(level, for: session.sessionId)
                            } label: {
                                Label(level.title, systemImage: level.systemImage)
                            }
                            .tint(level.tint)
                        }
                    }
                    .contextMenu {
                        ForEach(WatchLevel.allCases, id: \.self) { level in
                            Button {
                                settings.setWatchLevel(level, for: session.sessionId)
                            } label: {
                                Label(level.title, systemImage: level == settings.watchLevel(for: session.sessionId) ? "checkmark" : level.systemImage)
                            }
                        }
                        Divider()
                        Button {
                            Task { await rename(session) }
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button {
                            Task { await fork(session) }
                        } label: {
                            Label("派生新会话", systemImage: "arrow.branch")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("设置")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showWebConsole = true
            } label: {
                Image(systemName: "globe")
            }
            .accessibilityLabel("完整 Web 界面")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showCreateSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .disabled(isLoading)
        }
    }

    // MARK: - 数据

    @MainActor
    private func load() async {
        let api = APIClient(settings: settings)
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await api.listSessions()
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            hasLoaded = false
        }
    }

    @MainActor
    private func createSession(agentPreset: String? = nil) async {
        let api = APIClient(settings: settings)
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await api.createSession(agentPreset: agentPreset)
            // 新建后刷新列表，让用户进入最新会话
            await load()
        } catch {
            errorMessage = "新建失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func rename(_ session: SessionSummary) async {
        let current = session.projectedTitle ?? "会话"
        // 用系统输入框重命名
        let alert = UIAlertController(title: "重命名会话", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in tf.text = current }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in
            guard let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
            Task { @MainActor in
                do {
                    _ = try await APIClient(settings: settings).renameSession(sessionId: session.sessionId, title: text)
                    await load()
                } catch {
                    errorMessage = "重命名失败：\(error.localizedDescription)"
                }
            }
        })
        present(alert)
    }

    @MainActor
    private func fork(_ session: SessionSummary) async {
        let api = APIClient(settings: settings)
        do {
            let result = try await api.forkSession(sessionId: session.sessionId)
            await load()
            // 打开派生出的新会话
            notificationSession = NotificationSession(sessionId: result.sessionId)
        } catch {
            errorMessage = "派生失败：\(error.localizedDescription)"
        }
    }

    /// 在顶层 presented VC 上弹系统 alert（SwiftUI alert 无法携带文本输入框）
    private func present(_ controller: UIViewController) {
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        top?.present(controller, animated: true)
    }
}

// MARK: - 会话行

private struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(.purple.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.purple)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if session.running {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let tokenText {
                    Label(tokenText, systemImage: "tuningfork")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                if let permission = session.projectedPermission, permission != "workspace-write" {
                    Text(permission)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        if let title = session.projectedTitle, !title.isEmpty {
            return title
        }
        if session.blank { return "新会话" }
        return "会话"
    }

    private var subtitle: String {
        // 服务器 updatedAt 是毫秒时间戳，转成秒再建 Date
        let date = Date(timeIntervalSince1970: session.updatedAt / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        var s = fmt.string(from: date)
        if let cwd = session.cwd {
            s += " · " + cwd
        }
        return s
    }

    /// 累计 token 用量（输出/总计）
    private var tokenText: String? {
        guard let totals = session.projectedTokenUsage, totals.total > 0 else { return nil }
        return "输出 \(totals.short(totals.outputTokens)) · 总计 \(totals.short(totals.total))"
    }
}

/// 通知点击 → 跳转会话 的可识别包装（fullScreenCover(item:) 需要 Identifiable）
private struct NotificationSession: Identifiable {
    let id = UUID()
    let sessionId: String
}

// MARK: - 新建会话（选择 Agent 预设模式）

/// 新建会话的底部弹窗：选择 Agent 预设（标准/创造/极简/PTC/梁神模式…）
struct CreateSessionSheet: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    let onCreate: (String?) -> Void

    @State private var presets: [AgentPresetRow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载模式…")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "加载失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    List {
                        Section {
                            // 默认（跟随全局）
                            Button {
                                onCreate(nil)
                                dismiss()
                            } label: {
                                Label("默认（跟随全局）", systemImage: "gearshape")
                            }
                        }
                        Section("选择模式") {
                            ForEach(presets) { preset in
                                Button {
                                    onCreate(preset.id)
                                    dismiss()
                                } label: {
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
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("新建会话")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
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
            // 按 order 排序，isDefault 排最前
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
