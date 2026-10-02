// ============================================================================
//  WebShellControlSheet.swift — App 控制面板（原生叠加层）
//  ----------------------------------------------------------------------------
//  主界面是 Web 壳（官方 DSH Web），原生能力集中在这个控制面板管理：
//    · 通知 / 灵动岛开关
//    · 会话级「特别关注」（WatchLevel：跟随全局 / 特别关注 / 静音）
//    · 服务器与配对（重新配对 / 修改服务器 / 重新加载 Web）
//  ----------------------------------------------------------------------------
import SwiftUI

struct WebShellControlSheet: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// 重新加载 Web 界面（由 WebConsoleView 传入）
    let onReload: () -> Void

    @State private var sessions: [SessionSummary] = []
    @State private var sessionsLoaded = false
    @State private var sessionsError: String?
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            Form {
                // ---------------- 通知与灵动岛 ----------------
                Section {
                    Toggle("任务通知", isOn: $settings.notificationsEnabled)
                    Toggle("灵动岛 / 锁屏实时活动", isOn: $settings.liveActivitiesEnabled)
                } header: {
                    Text("通知与灵动岛")
                } footer: {
                    Text("任务完成、失败或向你提问时提醒；「特别关注」的会话在 App 前台也会弹横幅，静音的会话一律不提醒。")
                }

                // ---------------- 会话特别关注 ----------------
                Section {
                    if let sessionsError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("会话列表加载失败").font(.footnote).foregroundStyle(.secondary)
                            Button("重试") { loadSessions() }
                                .buttonStyle(.bordered)
                        }
                    } else if !sessionsLoaded {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if sessions.isEmpty {
                        Text("暂无会话").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(sessions) { session in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title(of: session))
                                        .lineLimit(1)
                                    Text(subtitle(of: session))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                watchMenu(for: session)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("会话特别关注")
                        Spacer()
                        Button("刷新") { loadSessions() }
                            .font(.footnote)
                    }
                } footer: {
                    Text("特别关注：任务结果必定提醒（前台也弹横幅）；静音：一律不提醒；跟随全局：只在后台提醒。")
                }

                // ---------------- 服务器与配对 ----------------
                Section("服务器与配对") {
                    LabeledContent("当前通道") {
                        Text(settings.activeChannel.label).foregroundStyle(.secondary)
                    }
                    LabeledContent("地址") {
                        Text(settings.activeBaseURL ?? "未设置")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button {
                        showSetup = true
                    } label: {
                        Label("重新配对 / 修改服务器", systemImage: "link.badge.plus")
                    }
                    Button {
                        onReload()
                        dismiss()
                    } label: {
                        Label("重新加载 Web 界面", systemImage: "arrow.clockwise")
                    }
                }

                // ---------------- 关于 ----------------
                Section("关于") {
                    LabeledContent("DSH 客户端", value: appVersion)
                    LabeledContent("设备 ID") {
                        Text(settings.deviceId.isEmpty ? "未配对" : String(settings.deviceId.prefix(8)) + "…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("App 控制")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { loadSessions() }
            .fullScreenCover(isPresented: $showSetup) {
                SetupView(mode: .settings)
                    .environmentObject(settings)
            }
        }
    }

    // MARK: - 会话列表

    private func loadSessions() {
        sessionsError = nil
        sessionsLoaded = false
        let api = APIClient(settings: settings)
        Task {
            do {
                let items = try await api.listSessions()
                sessions = items
                sessionsLoaded = true
            } catch {
                sessionsLoaded = true
                sessionsError = error.localizedDescription
            }
        }
    }

    /// 会话标题：projections.title 优先，空会话显示「新会话」
    private func title(of session: SessionSummary) -> String {
        if let title = session.projections?.objectValue?["title"]?.stringValue,
           !title.isEmpty {
            return title
        }
        return session.blank ? "新会话" : "会话"
    }

    /// 会话副标题：更新时间 + 工作目录
    private func subtitle(of session: SessionSummary) -> String {
        let date = Date(timeIntervalSince1970: session.updatedAt / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var text = formatter.string(from: date)
        if let cwd = session.cwd, !cwd.isEmpty {
            text += " · " + cwd
        }
        return text
    }

    // MARK: - 特别关注菜单

    @ViewBuilder
    private func watchMenu(for session: SessionSummary) -> some View {
        let current = settings.watchLevel(for: session.sessionId)
        Menu {
            ForEach(WatchLevel.allCases) { level in
                Button {
                    settings.setWatchLevel(level, for: session.sessionId)
                } label: {
                    Label(level.title, systemImage: current == level ? "checkmark" : level.systemImage)
                }
            }
        } label: {
            Label(current.title, systemImage: current.systemImage)
                .font(.footnote)
        }
        .fixedSize()
    }

    // MARK: - 版本

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
