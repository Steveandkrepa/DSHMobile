// ============================================================================
//  SettingsViewModel.swift — DSH 设置视图模型（全量命名空间 + 凭证）
//  ----------------------------------------------------------------------------
//  职责：
//    · 调 settings/describe 拉取全部命名空间（writable/hasDocument 由服务端决定）。
//    · 对每个命名空间维护一份"工作副本"（value 深拷贝），编辑时直接改副本，
//      保存时用 settings/replace（整体 section + expectedRevision）写回；
//      版本冲突（服务端已变）时自动重读最新值并提示用户重试。
//    · 凭证管理：credentials/describe（refs=[] 拉全量）、set、unset。
// ============================================================================
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    enum LoadState {
        case idle, loading, loaded, failed(String)
    }

    // MARK: - 状态
    @Published var namespaces: [SettingsNamespaceView] = []
    @Published var loadState: LoadState = .idle
    @Published var errorMessage: String?
    @Published var savingNamespace: String?

    /// 每个命名空间的工作副本（key = ns；与 revision 绑定）
    private var workingByNS: [String: AnyCodable] = [:]
    private var revisionByNS: [String: Int] = [:]

    private let api: APIClient
    private let settings: AppSettings

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings.shared
        self.api = APIClient(settings: self.settings)
    }

    // MARK: - 加载

    func load() async {
        loadState = .loading
        do {
            let value = try await api.describeSettings()
            guard value.writable else {
                loadState = .failed("该通道为只读（writable=false）")
                return
            }
            namespaces = value.namespaces
            // 初始化工作副本与修订号
            workingByNS = [:]
            revisionByNS = [:]
            for ns in value.namespaces {
                workingByNS[ns.ns] = JSONValue.deepCopy(ns.value)
                revisionByNS[ns.ns] = ns.revision
            }
            loadState = .loaded
        } catch {
            errorMessage = error.localizedDescription
            loadState = .failed(error.localizedDescription)
        }
    }

    // MARK: - 工作副本读写

    /// 取某命名空间的工作副本
    func workingValue(for ns: String) -> AnyCodable? {
        workingByNS[ns]
    }

    /// 替换整个工作副本
    func setWorkingValue(_ value: AnyCodable?, for ns: String) {
        workingByNS[ns] = value
    }

    /// 局部修改工作副本（key 级）
    func patchWorkingValue(_ patch: [String: AnyCodable], for ns: String) {
        var obj = workingByNS[ns]?.objectValue ?? [:]
        for (k, v) in patch {
            obj[k] = v
        }
        workingByNS[ns] = .object(obj)
    }

    /// 当前修订号
    func revision(for ns: String) -> Int? {
        revisionByNS[ns]
    }

    // MARK: - 保存（settings/replace，带修订冲突重读）

    /// 保存某个命名空间；成功返回 true。失败抛错（含修订冲突）。
    /// 冲突时：自动重读该命名空间最新值，更新工作副本，并抛出带提示的错误。
    func save(ns: String) async throws {
        guard let working = workingByNS[ns] else { return }
        savingNamespace = ns
        defer { savingNamespace = nil }

        let object = working.objectValue ?? [:]
        let section = object.mapValues(AnyCodable.fromAny)
        let expected = revisionByNS[ns]

        do {
            let result = try await api.replaceSettings(
                ns: ns,
                section: section,
                expectedRevision: expected
            )
            revisionByNS[ns] = result.revision
            workingByNS[ns] = result.value ?? working
        } catch let error as APIError {
            switch error {
            case .rpc(_, let message) where message.contains("changed since it was read"):
                // 修订冲突：重读最新值
                if let fresh = try? await refreshNamespace(ns) {
                    workingByNS[ns] = JSONValue.deepCopy(fresh.value)
                    revisionByNS[ns] = fresh.revision
                }
                throw error
            default:
                throw error
            }
        }
    }

    /// 只重读一个命名空间（settings/describe 全量太重；此处用 replace 的返回兜底，
    /// 实际上 describe 是全量的，这里简单重读一次全量并只取该 ns）
    private func refreshNamespace(_ ns: String) async throws -> SettingsNamespaceView {
        let value = try await api.describeSettings()
        guard let fresh = value.namespaces.first(where: { $0.ns == ns }) else {
            throw APIError.rpc(code: "settings/not-found", message: "命名空间 \(ns) 不存在")
        }
        return fresh
    }

    // MARK: - 凭证

    /// 拉取全部凭证（refs=[]）
    func loadCredentials() async throws -> [String: AnyCodable] {
        let value = try await api.describeCredentials(refs: [])
        return value?.objectValue ?? [:]
    }

    /// 设置凭证
    func setCredential(ref: String, value: String) async throws {
        _ = try await api.setCredential(ref: ref, value: value)
    }

    /// 清除凭证
    func unsetCredential(ref: String) async throws {
        _ = try await api.unsetCredential(ref: ref)
    }
}

// MARK: - AnyCodable 扩展

extension AnyCodable {
    /// 从 Swift 任意值构造 AnyCodable（供 section 序列化）
    static func fromAny(_ value: Any) -> AnyCodable {
        switch value {
        case let v as AnyCodable: return v
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as [Any]: return .array(v.map(fromAny))
        case let v as [String: Any]: return .object(v.mapValues(fromAny))
        default: return .null
        }
    }
}
