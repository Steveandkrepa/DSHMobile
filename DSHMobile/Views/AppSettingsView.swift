// ============================================================================
//  AppSettingsView.swift — 原生 App 设置
//  ----------------------------------------------------------------------------
//  原生设置面板（App 入口）：
//    · 通知与灵动岛开关
//    · 会话「特别关注」（watch level）管理
//    · 服务器与配对（重新配对 / 当前通道）
//    · 完整 Web 界面（官方 DSH Web 全功能兜底，设置等复杂页面用 Web 组件）
//    · 关于（版本 / 设备 ID）
// ============================================================================
import SwiftUI
import UIKit

struct AppSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [SessionSummary] = []
    @State private var sessionsLoaded = false
    @State private var sessionsError: String?
    @State private var showSetup = false
    @State private var showWebConsole = false

    var body: some View {
        Form {
            Section {
                LabeledContent("当前通道", value: settings.activeChannel.label)
                if let base = settings.activeBaseURL, !base.isEmpty {
                    LabeledContent("地址", value: base)
                }
            } header: {
                Text("服务器与配对")
            } footer: {
                Text("扫码配对后 App 会自动向服务器请求局域网/公网地址并补全。")
            }

            Section {
                Toggle("任务通知", isOn: $settings.notificationsEnabled)
                Toggle("灵动岛 / 锁屏实时活动", isOn: $settings.liveActivitiesEnabled)
            } header: {
                Text("通知与灵动岛")
            } footer: {
                Text("任务完成、失败或向你提问时通知；聚焦中的会话在前台也会提醒。")
            }

            Section {
                if let sessionsError {
                    HStack {
                        Text(sessionsError).font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("重试") { Task { await loadSessions() } }
                    }
                } else if !sessionsLoaded {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if sessions.isEmpty {
                    Text("暂无会话").foregroundStyle(.secondary)
                } else {
                    ForEach(sessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(of: session)).lineLimit(1)
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
                    Button {
                        Task { await loadSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.footnote)
                }
            } footer: {
                Text("「特别关注」的会话会始终提醒（前台也弹横幅）；「静音」则完全安静。Web 壳里当前打开的会话会自动设为特别关注。")
            }

            Section {
                Button {
                    showWebConsole = true
                } label: {
                    Label("完整 Web 界面", systemImage: "globe")
                }
                .accessibilityLabel("打开完整 Web 界面")
                Button {
                    showSetup = true
                } label: {
                    Label("重新配对 / 修改服务器", systemImage: "link.badge.plus")
                }
            } header: {
                Text("Web 组件")
            } footer: {
                Text("官方 DSH Web 全功能（设置 · 凭证 · 模型管理）都可以在完整 Web 界面里操作。")
            }

            Section {
                LabeledContent("DSH 客户端", value: appVersion)
                LabeledContent("设备 ID", value: String(settings.deviceId.prefix(8)) + "…")
            } header: {
                Text("关于")
            }
        }
        .navigationTitle("App 设置")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .sheet(isPresented: $showWebConsole) {
            NavigationStack {
                WebConsoleView()
                    .environmentObject(settings)
            }
        }
        .fullScreenCover(isPresented: $showSetup) {
            SetupView(mode: .settings)
                .environmentObject(settings)
        }
        .task { await loadSessions() }
        .onChange(of: settings.watchLevelsRevision) { _, _ in
            // 关注级别变化 → 刷新（显示新的选中态）
            Task { await loadSessions() }
        }
    }

    @ViewBuilder
    private func watchMenu(for session: SessionSummary) -> some View {
        let current = settings.watchLevel(for: session.sessionId)
        Menu {
            ForEach(WatchLevel.allCases, id: \.self) { level in
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

    @MainActor
    private func loadSessions() async {
        let api = APIClient(settings: settings)
        sessionsError = nil
        sessionsLoaded = false
        do {
            sessions = try await api.listSessions()
            sessionsLoaded = true
        } catch {
            sessionsLoaded = true
            sessionsError = error.localizedDescription
        }
    }

    private func title(of session: SessionSummary) -> String {
        if let title = session.projectedTitle, !title.isEmpty { return title }
        return session.blank ? "新会话" : "会话"
    }

    private func subtitle(of session: SessionSummary) -> String {
        let date = Date(timeIntervalSince1970: session.updatedAt / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        var s = fmt.string(from: date)
        if let cwd = session.cwd { s += " · " + cwd }
        return s
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}
