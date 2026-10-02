// ============================================================================
//  SessionListView.swift — 会话列表
//  ----------------------------------------------------------------------------
//  拉取 session.list（HTTP RPC），展示历史会话，支持新建/刷新/进入聊天。
//  标题来源：session.list 的 projections.title，回退到创建时间。
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
    /// 通知点击 → 要打开的会话（fullScreenCover 呈现，避免与导航栈冲突）
    @State private var notificationSession: NotificationSession?

    var body: some View {
        NavigationStack {
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
                SettingsView()
                    .environmentObject(settings)
            }
            .sheet(isPresented: $showWebConsole) {
                NavigationStack {
                    WebConsoleView()
                        .environmentObject(settings)
                }
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
                        ChatView(sessionId: session.sessionId)
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
                Task { await createSession() }
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
    private func createSession() async {
        let api = APIClient(settings: settings)
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await api.createSession()
            // 新建后直接进入聊天
            let summary = SessionSummary(
                sessionId: result.sessionId,
                // 服务器 updatedAt 是毫秒，本地同样用毫秒保持一致
                updatedAt: Date().timeIntervalSince1970 * 1000,
                agentAvailable: true,
                running: false,
                blank: true,
                cwd: nil,
                parentSessionId: nil,
                origin: nil,
                projections: nil
            )
            sessions.insert(summary, at: 0)
            // 简单刷新列表
            await load()
        } catch {
            errorMessage = "新建失败：\(error.localizedDescription)"
        }
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
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        // projections 里可能带 title（DSH Web 显示用）
        if let title = session.projections?.objectValue?["title"]?.stringValue, !title.isEmpty {
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
}

/// 通知点击 → 跳转会话 的可识别包装（fullScreenCover(item:) 需要 Identifiable）
private struct NotificationSession: Identifiable {
    let id = UUID()
    let sessionId: String
}
