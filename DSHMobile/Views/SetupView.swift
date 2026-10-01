// ============================================================================
//  SetupView.swift — 配对 / 设置页
//  ----------------------------------------------------------------------------
//  两种用法：
//    · mode = .initial：首次启动，必须配对成功才能进入会话列表。
//    · mode = .settings：已配对后从设置页进入，可改地址/重新配对/解除配对。
//
//  配对流程：
//    1. 填「局域网地址」「公网地址」（至少一个）。
//    2. 在电脑/其他设备打开配对链接（如 https://<id>.dsh-market.com/pair-accept?pair=<token>），
//       或用 dsh-pair.cjs issue 拿到一次性 token。
//    3. 粘贴 token → 客户端 POST {base}/api/pair/accept → 拿 deviceId 并保存。
// ============================================================================
import SwiftUI

struct SetupView: View {
    enum Mode { case initial, settings }

    let mode: Mode
    @EnvironmentObject var settings: AppSettings

    @State private var lanURL = ""
    @State private var publicURL = ""
    @State private var token = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showingHelp = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(mode == .initial
                         ? "欢迎使用 DSH 移动客户端"
                         : "连接设置")
                        .font(.headline)
                    Text("连接到你的 DeepSeek Harness（DSH）Web 服务。地址至少填一个，客户端会自动检测：局域网优先直连，否则走公网中转。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("服务器地址") {
                    TextField("局域网地址（如 http://192.168.0.142:3080）", text: $lanURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("公网地址（如 https://xxxx.dsh-market.com）", text: $publicURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if mode == .initial {
                    Section("配对令牌") {
                        TextField("粘贴配对 token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            showingHelp = true
                        } label: {
                            Label("如何获取配对令牌？", systemImage: "questionmark.circle")
                                .font(.footnote)
                        }
                    }

                    Section {
                        Button {
                            Task { await pair() }
                        } label: {
                            if isBusy {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("配对中…")
                                }
                            } else {
                                Text("配对并连接").bold()
                            }
                        }
                        .disabled(isBusy || !canPair)
                    } footer: {
                        Text("配对成功后即可浏览会话并聊天。令牌一次性使用。")
                    }
                }

                if mode == .settings {
                    if !settings.deviceId.isEmpty {
                        Section("当前设备") {
                            LabeledContent("设备 ID", value: settings.deviceId)
                            LabeledContent("当前通道", value: settings.activeChannel.label)
                        }
                    }

                    Section {
                        Button {
                            Task { await pair() }
                        } label: {
                            if isBusy {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("重新配对…")
                                }
                            } else {
                                Text("用新令牌重新配对")
                            }
                        }
                        .disabled(isBusy || !canPair)

                        Button(role: .destructive) {
                            settings.markUnpaired()
                        } label: {
                            Text("解除配对并退出")
                        }
                    }
                }
            }
            .navigationTitle(mode == .initial ? "开始使用" : "设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if mode == .settings {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .alert("配对失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showingHelp) {
                HelpSheet()
            }
            .onAppear(perform: loadCurrent)
        }
    }

    private var canPair: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!lanURL.isEmpty || !publicURL.isEmpty)
    }

    @MainActor
    private func loadCurrent() {
        if lanURL.isEmpty { lanURL = settings.lanURL }
        if publicURL.isEmpty { publicURL = settings.publicURL }
    }

    /// 配对：POST /api/pair/accept（走根路径，不经过 /remote 镜像）
    @MainActor
    private func pair() async {
        guard !token.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        let api = APIClient(settings: settings)
        guard let base = settings.pairingBase(for: lanURL, publicURL: publicURL) else {
            errorMessage = "请至少填一个服务器地址"
            return
        }
        do {
            let resp = try await api.pairAccept(token: token, base: base)
            guard resp.ok, let deviceId = resp.deviceId, !deviceId.isEmpty else {
                errorMessage = resp.code ?? "配对失败（服务器拒绝了令牌）"
                return
            }
            settings.save(lanURL: lanURL, publicURL: publicURL, deviceId: deviceId)
            if mode == .settings { dismiss() }
        } catch {
            // 公网失败 → 尝试局域网
            if let lan = URL(string: lanURL), lan.scheme != nil {
                do {
                    let resp = try await api.pairAccept(token: token, base: settings.normalized(lanURL))
                    guard resp.ok, let deviceId = resp.deviceId, !deviceId.isEmpty else {
                        errorMessage = resp.code ?? "配对失败（服务器拒绝了令牌）"
                        return
                    }
                    settings.save(lanURL: lanURL, publicURL: publicURL, deviceId: deviceId)
                    if mode == .settings { dismiss() }
                    return
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 配对帮助

private struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("方法一：电脑端 DSH 配对页") {
                    Text("""
                    1. 在电脑上打开 DSH Web 界面。
                    2. 进入「设置 → 远程设备」，点击「添加设备」。
                    3. 把生成的配对链接复制到手机，或复制其中的 token 粘贴到本页。
                    """)
                }
                Section("方法二：命令行") {
                    Text("""
                    在 DSH 主机上执行：
                    node dsh-pair.cjs issue
                    会打印类似：
                    https://<id>.dsh-market.com/pair-accept?pair=<token>
                    复制 token 即可。
                    """)
                }
                Section("注意事项") {
                    Text("""
                    · 局域网地址用于同一 WiFi 直连（延迟低、不经公网）。
                    · 公网地址走 Cloudflare 隧道/中继，任何网络都能连。
                    · 客户端自动检测：先试局域网，超时自动切公网。
                    · 令牌一次性有效，配对成功后保存的设备 ID 长期有效。
                    """)
                }
            }
            .navigationTitle("如何配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { dismiss() }
                }
            }
        }
    }
}
