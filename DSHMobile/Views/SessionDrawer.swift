// ============================================================================
//  SessionDrawer.swift
//  原生会话抽屉。
//
//  为什么需要它：网页控制台在窄屏（< 1024 px，见 dsh-client-ui-layout 的
//  SIDEBAR_AUTO_COLLAPSE）会把侧栏压成 56 px 轨道，会话行被裁剪；同时侧栏
//  行会被虚拟化（离屏行从 DOM 移除），手机上很难可靠地点到某个会话。
//  这里用官方 RPC（session/list、session/rename）渲染一份原生列表：
//    · 一览：最近会话（正在运行的置顶并标记）
//    · 一键打开：交给外壳在网页里点对应会话行（DOM 代理点击）
//    · 一键新建：交给外壳点网页的「新建会话」
//    · 会话级通知关注级别（跟随全局 / 特别关注 / 静音）、重命名
//  目标是不论网页侧边栏在手机上表现如何，「换会话」永远可用。
// ============================================================================
import SwiftUI

struct SessionDrawer: View {
    @EnvironmentObject var settings: AppSettings

    /// 当前网页正在展示的会话（用于高亮）
    let currentSessionId: String?
    /// 在网页里打开某个会话
    let onOpen: (String) -> Void
    /// 新建会话（网页侧栏入口）
    let onNewSession: () -> Void
    /// 打开 App 设置
    let onOpenSettings: () -> Void
    /// 重新加载网页控制台（网页卡住时的自救入口）
    let onReload: () -> Void
    let onClose: () -> Void

    @State private var sessions: [SessionSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var renameTarget: SessionSummary?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                sessionsContent
                settingsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { onClose() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onNewSession()
                        onClose()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新建会话")
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .alert("重命名会话", isPresented: $showRenameAlert) {
                TextField("会话名称", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("保存") {
                    let target = renameTarget
                    renameTarget = nil
                    Task { await commitRename(target) }
                }
            } message: {
                Text("给这个会话起一个更好找的名字。")
            }
        }
    }

    // MARK: - 分区

    private var statusSection: some View {
        Section {
            LabeledContent("连接") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(settings.activeBaseURL == nil ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(settings.activeChannel.label)
                        .font(.footnote)
                }
            }
            if let base = settings.activeBaseURL {
                LabeledContent("地址") {
                    Text(base)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } header: {
            Text("服务器")
        }
    }

    @ViewBuilder
    private var sessionsContent: some View {
        if isLoading && sessions.isEmpty {
            Section {
                HStack {
                    ProgressView()
                    Text("正在读取会话…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else if sessions.isEmpty {
            Section {
                Text("还没有会话，点右上角新建一个。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(groups, id: \.key) { group in
                Section {
                    ForEach(group.sessions) { session in
                        sessionRow(session)
                    }
                } header: {
                    Text(groupTitle(group.key))
                }
            }
        }
    }

    private var settingsSection: some View {
        Section {
            Button {
                onOpenSettings()
            } label: {
                Label("App 设置", systemImage: "gearshape")
            }
            Button {
                onReload()
                onClose()
            } label: {
                Label("重新加载网页", systemImage: "arrow.clockwise")
            }
        } footer: {
            Text("通知、灵动岛、特别关注、服务器与配对都在「App 设置」里；网页白屏或卡住时用「重新加载网页」。")
        }
    }

    // MARK: - 行

    private func sessionRow(_ session: SessionSummary) -> some View {
        Button {
            onOpen(session.sessionId)
            onClose()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: session.running ? "bolt.circle.fill" : "bubble.left")
                    .foregroundStyle(session.running ? Color.purple : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayTitle(session))
                            .font(.subheadline)
                            .lineLimit(1)
                        if settings.watchLevel(for: session.sessionId) == .focused {
                            Image(systemName: "bell.badge.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if settings.watchLevel(for: session.sessionId) == .muted {
                            Image(systemName: "bell.slash")
                                .font(.caption2)
                                .foregroundStyle(.gray)
                        }
                    }
                    HStack(spacing: 6) {
                        if session.running {
                            Text("运行中")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.purple)
                        }
                        Text(timeLabel(session))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if session.sessionId == currentSessionId {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                watchMenu(session)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                renameTarget = session
                renameText = session.projectedTitle ?? ""
                showRenameAlert = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    private func watchMenu(_ session: SessionSummary) -> some View {
        Menu {
            ForEach(WatchLevel.allCases) { level in
                Button {
                    settings.setWatchLevel(level, for: session.sessionId)
                } label: {
                    Label(level.title, systemImage: level.systemImage)
                }
            }
        } label: {
            Image(systemName: "bell")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("通知关注级别")
    }

    // MARK: - 数据

    private struct SessionGroup {
        let key: String
        let sessions: [SessionSummary]
    }

    /// 按工作目录分组：默认工作区在最前，其余按路径排序；组内运行中优先、再按更新时间倒序
    private var groups: [SessionGroup] {
        var byCwd: [String: [SessionSummary]] = [:]
        for session in sessions {
            let key = session.cwd?.isEmpty == false ? (session.cwd ?? "") : ""
            byCwd[key, default: []].append(session)
        }
        return byCwd
            .map { key, list in
                SessionGroup(
                    key: key,
                    sessions: list.sorted { a, b in
                        if a.running != b.running { return a.running }
                        return a.updatedAt > b.updatedAt
                    }
                )
            }
            .sorted { a, b in
                if (a.key == "") != (b.key == "") { return a.key != "" }
                return a.key < b.key
            }
    }

    private func groupTitle(_ key: String) -> String {
        if key.isEmpty { return "未指定目录" }
        let name = (key as NSString).lastPathComponent
        return name.isEmpty ? key : name
    }

    private func displayTitle(_ session: SessionSummary) -> String {
        if let title = session.projectedTitle, !title.isEmpty { return title }
        return session.blank ? "新会话" : "会话 \(session.sessionId.prefix(8))"
    }

    private func timeLabel(_ session: SessionSummary) -> String {
        let date = Date(timeIntervalSince1970: session.updatedAt / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func load() async {
        do {
            let list = try await APIClient(settings: settings).listSessions()
            sessions = list
            errorMessage = nil
        } catch {
            errorMessage = "读取会话失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func commitRename(_ target: SessionSummary?) async {
        guard let target else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            _ = try await APIClient(settings: settings).renameSession(sessionId: target.sessionId, title: title)
            await load()
        } catch {
            errorMessage = "重命名失败：\(error.localizedDescription)"
        }
    }
}
