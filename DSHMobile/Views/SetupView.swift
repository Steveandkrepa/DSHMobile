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
import UIKit

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
    @State private var showingScanner = false
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
                            showingScanner = true
                        } label: {
                            Label("扫描配对链接二维码", systemImage: "qrcode.viewfinder")
                                .font(.footnote)
                        }
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

                        Button {
                            showingScanner = true
                        } label: {
                            Label("扫描配对链接二维码", systemImage: "qrcode.viewfinder")
                        }
                        .disabled(isBusy)

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
                Button("复制详情") {
                    UIPasteboard.general.string = errorMessage ?? ""
                }
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showingHelp) {
                HelpSheet()
            }
            .fullScreenCover(isPresented: $showingScanner) {
                QRScannerContainer(token: $token, lanURL: $lanURL, publicURL: $publicURL, autoPair: {
                    // 地址已填好才自动发起配对；否则只填 token，等用户补地址后手动点配对
                    if !lanURL.isEmpty || !publicURL.isEmpty {
                        Task { await pair() }
                    }
                })
            }
            .onAppear(perform: loadCurrent)
        }
    }

    private var canPair: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!lanURL.isEmpty || !publicURL.isEmpty)
    }

    /// 从二维码载荷中提取配对信息。支持的载荷格式：
    ///   1. 官方配对链接（含可选 lan/pub 扩展参数）：
    ///      https://<public>.dsh-market.com/pair-accept?pair=<token>&lan=<urlencoded>&pub=<urlencoded>
    ///        → token = pair 参数；lan/pub 显式给出局域网与公网地址；
    ///        → 无 lan/pub 时兜底：publicURL = scheme://host（隧道域名即公网地址）
    ///   2. 裸 token / 其他格式 → 原样 trim 后返回
    static func parse(_ payload: String) -> (token: String, publicURL: String?, lanURL: String?) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        var token: String?
        var publicURL: String?
        var lanURL: String?
        if let comps = URLComponents(string: trimmed) {
            let items = comps.queryItems ?? []
            if let pair = items.first(where: { $0.name == "pair" })?.value, !pair.isEmpty {
                token = pair
            }
            if let lan = items.first(where: { $0.name == "lan" })?.value, !lan.isEmpty {
                lanURL = lan.removingPercentEncoding ?? lan
            }
            if let pub = items.first(where: { $0.name == "pub" })?.value, !pub.isEmpty {
                publicURL = pub.removingPercentEncoding ?? pub
            }
            // 兜底：没有 pub 参数时，用链接主机推导公网地址
            if publicURL == nil, let scheme = comps.scheme, let host = comps.host, !host.isEmpty {
                publicURL = "\(scheme)://\(host)"
            }
        }
        // 兜底：字符串里内联了 pair=xxx
        if token == nil, trimmed.contains("pair=") {
            let parts = trimmed.components(separatedBy: "pair=")
            if parts.count > 1 {
                let rest = parts[1]
                let t = rest.split(whereSeparator: { $0 == "&" || $0.isWhitespace }).first.map(String.init) ?? rest
                if !t.isEmpty { token = t }
            }
        }
        return (token ?? trimmed, publicURL, lanURL)
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

// MARK: - 扫码配对容器

/// 全屏扫码：VisionKit 相机 + 右上角关闭按钮；扫到后自动提取 token 并填入局域网/公网地址，随后触发配对
private struct QRScannerContainer: View {
    @Binding var token: String
    @Binding var lanURL: String
    @Binding var publicURL: String
    /// 令牌填好后自动发起配对
    var autoPair: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScannerView(onScan: handleScan) {
                dismiss()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .padding(.top, 16)
            .padding(.trailing, 16)
        }
        .ignoresSafeArea()
    }

    private func handleScan(_ payload: String) {
        let parsed = SetupView.parse(payload)
        token = parsed.token
        if let lan = parsed.lanURL, !lan.isEmpty, lanURL.isEmpty {
            lanURL = lan
        }
        if let pub = parsed.publicURL, !pub.isEmpty, publicURL.isEmpty {
            publicURL = pub
        }
        dismiss()
        // 地址已填好（手动填或扫码自动推导）的话直接发起配对
        autoPair()
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
                Section("方法三：扫码配对（推荐）") {
                    Text("""
                    1. 电脑端执行 `node dsh-pair.cjs issue`，或 DSH Web「设置 → 远程设备」生成配对链接。
                    2. 让配对链接的二维码显示在电脑屏幕上（终端/浏览器会渲染二维码）。
                    3. App 里点「扫描配对链接二维码」，对准屏幕即可自动完成配对。
                    """)
                }
                Section("注意事项") {
                    Text("""
                    · 局域网地址用于同一 WiFi 直连（延迟低、不经公网）。
                    · 公网地址走 Cloudflare 隧道/中继，任何网络都能连。
                    · 客户端自动检测：先试局域网，超时自动切公网。
                    · 令牌一次性有效，配对成功后保存的设备 ID 长期有效。
                    · 扫码需要相机权限，第一次会弹授权。
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
