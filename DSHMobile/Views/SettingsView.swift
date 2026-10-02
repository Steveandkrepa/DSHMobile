// ============================================================================
//  SettingsView.swift — DSH 设置页（全量功能）
//  ----------------------------------------------------------------------------
//  三个区块：
//    1. 服务器与配对（复用 SetupView(mode: .settings)）
//    2. DSH 设置全量（命名空间列表 → 每个命名空间一个 schema 驱动表单，
//       保存走 settings/replace + 修订冲突保护）
//    3. 凭证管理（credentials/describe + set + unset）
// ============================================================================
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var viewModel = SettingsViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showPairing = false
    @State private var credentials: [String: AnyCodable] = [:]
    @State private var credentialsLoaded = false
    @State private var showCredentialError: String?

    var body: some View {
        NavigationStack {
            List {
                // 1. 服务器与配对
                Section("服务器与配对") {
                    Button {
                        showPairing = true
                    } label: {
                        HStack {
                            Label("配对与服务器设置", systemImage: "link.badge.plus")
                            Spacer()
                            Text(settings.activeChannel.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 2. DSH 设置全量
                Section {
                    switch viewModel.loadState {
                    case .idle, .loading:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("加载设置…")
                                .foregroundStyle(.secondary)
                        }
                    case .failed(let msg):
                        VStack(alignment: .leading, spacing: 8) {
                            Text("设置加载失败").font(.subheadline).foregroundStyle(.red)
                            Text(msg).font(.footnote).foregroundStyle(.secondary)
                            Button("重试") { Task { await viewModel.load() } }
                        }
                    case .loaded:
                        ForEach(viewModel.namespaces) { ns in
                            NavigationLink {
                                SchemaFormView(namespace: ns, viewModel: viewModel)
                            } label: {
                                HStack {
                                    Text(ns.displayName)
                                    Spacer()
                                    Text("rev \(ns.revision)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("DSH 设置")
                } footer: {
                    Text("共 \(viewModel.namespaces.count) 个命名空间，全部经由配对通道读写（与浏览器端设置一致）。")
                }

                // 3. 凭证管理
                Section {
                    if !credentialsLoaded {
                        Button("加载凭证") {
                            Task { await loadCredentials() }
                        }
                    } else {
                        ForEach(Array(credentials.keys).sorted(), id: \.self) { ref in
                            CredentialRow(ref: ref, value: credentials[ref], onUnset: { unset(ref: ref) })
                        }
                        if credentials.isEmpty {
                            Text("无已保存凭证").foregroundStyle(.secondary)
                        }
                        NavigationLink("添加凭证") {
                            CredentialAddView(onAdd: { ref, value in
                                Task { await addCredential(ref: ref, value: value) }
                            })
                        }
                    }
                } header: {
                    Text("凭证")
                } footer: {
                    Text("模型 API Key 等敏感信息，只显示存在与否，不显示明文。")
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showPairing) {
                SetupView(mode: .settings)
                    .environmentObject(settings)
            }
            .task {
                await viewModel.load()
            }
            .alert("出错了", isPresented: Binding(
                get: { showCredentialError != nil },
                set: { if !$0 { showCredentialError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(showCredentialError ?? "")
            }
        }
    }

    // MARK: - 凭证

    private func loadCredentials() async {
        credentialsLoaded = false
        do {
            credentials = try await viewModel.loadCredentials()
        } catch {
            showCredentialError = error.localizedDescription
        }
        credentialsLoaded = true
    }

    private func unset(ref: String) {
        Task { @MainActor in
            do {
                try await viewModel.unsetCredential(ref: ref)
                credentials.removeValue(forKey: ref)
            } catch {
                showCredentialError = error.localizedDescription
            }
        }
    }

    private func addCredential(ref: String, value: String) {
        Task { @MainActor in
            do {
                try await viewModel.setCredential(ref: ref, value: value)
                await loadCredentials()
            } catch {
                showCredentialError = error.localizedDescription
            }
        }
    }
}

// MARK: - 凭证行

struct CredentialRow: View {
    let ref: String
    let value: AnyCodable?
    let onUnset: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(ref)
                Text(valueDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("清除", role: .destructive) { onUnset() }
        }
    }

    private var valueDescription: String {
        guard let value else { return "已设置" }
        if case .string(let s) = value {
            if s.count > 20 { return "••••" + s.suffix(4) }
            return "••••\(s.suffix(4))"
        }
        return "已设置"
    }
}

// MARK: - 添加凭证

struct CredentialAddView: View {
    let onAdd: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ref = ""
    @State private var value = ""

    var body: some View {
        Form {
            Section("凭证引用（如 llm:deepseek/apiKey）") {
                TextField("ref", text: $ref)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            Section("值") {
                SecureField("值", text: $value)
            }
            Section {
                Button("保存") {
                    guard !ref.isEmpty, !value.isEmpty else { return }
                    onAdd(ref, value)
                    dismiss()
                }
                .disabled(ref.isEmpty || value.isEmpty)
            }
        }
        .navigationTitle("添加凭证")
    }
}
