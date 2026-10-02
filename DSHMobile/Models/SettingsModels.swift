// ============================================================================
//  SettingsModels.swift — DSH 设置（schemastery schema）数据模型
//  ----------------------------------------------------------------------------
//  来自 settings/describe 的命名空间视图：
//    {
//      "ns": "ui-theme",
//      "revision": 2,
//      "autoGenerate": false,
//      "schema": { "uid": <rootUid>, "refs": { "<uid>": node, ... } },
//      "value": <当前生效值>,
//      "base": <出厂默认>,
//      "user": <用户覆盖层（可选）>,
//      "secrets": [...]
//    }
//
//  schemastery 序列化格式：
//    · 顶层 {"uid": <rootUid>, "refs": {uid: node}}；根节点 = refs[rootUid]
//    · node 字段：type、meta{...}、dict{字段名:uid}（object）、list[uid]（union/array）、
//      inner(uid)（array/dict 的元素）、value（const 的固定值）、sKey(uid)（dict 键 schema）
//    · 节点类型：any / array / boolean / const / dict / number / object / string / union
// ============================================================================
import Foundation

// MARK: - settings/describe 顶层响应

/// settings/describe 的完整响应
struct SettingsDescribeValue: Decodable {
    let writable: Bool
    let hasDocument: Bool
    let namespaces: [SettingsNamespaceView]
    let defaults: [String: AnyCodable]?
    let user: [String: AnyCodable]?
    let revision: Int?
}

/// 一个设置命名空间的视图
struct SettingsNamespaceView: Decodable, Identifiable {
    let ns: String
    let revision: Int
    let autoGenerate: Bool
    let schema: SchemaDoc?
    let value: AnyCodable?
    let base: AnyCodable?
    let user: AnyCodable?
    let secrets: [AnyCodable]?

    var id: String { ns }

    /// 展示名（ns 去连字符、首字母大写）
    var displayName: String {
        ns.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    /// 是否有实际内容可编辑（schema 非空且非纯 any）
    var editable: Bool { schema != nil }
}

// MARK: - schemastery schema

/// schema 文档：{uid: 根节点 uid, refs: uid → 节点}
struct SchemaDoc: Decodable {
    let uid: Int
    let refs: [String: SchemaNode]

    /// 取根节点
    var root: SchemaNode? { refs[String(uid)] }

    /// 取任意节点
    func node(_ uid: Int) -> SchemaNode? { refs[String(uid)] }
}

/// schemastery 节点
struct SchemaNode: Decodable {
    let type: String
    let meta: SchemaMeta?
    /// object：字段名 → 子节点 uid
    let dict: [String: Int]?
    /// union：成员 uid 列表
    let list: [Int]?
    /// array/dict：元素/值的 uid
    let inner: Int?
    /// dict：键 schema uid
    let sKey: Int?
    /// const：固定值
    let value: AnyCodable?
    /// 未知/扩展字段
    let bits: AnyCodable?

    var metaOrEmpty: SchemaMeta { meta ?? SchemaMeta() }
}

/// 节点元数据
struct SchemaMeta: Decodable {
    /// JSON 字段名就是 "default"（Swift 关键字，用反引号转义）
    let `default`: AnyCodable?
    let required: Bool?
    let disabled: Bool?
    let collapse: Bool?
    let hidden: Bool?
    let role: String?
    let description: String?
    let comment: String?
    let pattern: String?
    let max: Double?
    let min: Double?
    let step: Double?
    let badges: [String]?
    let link: String?

    /// 无歧义别名
    var defaultValue: AnyCodable? { `default` }

    init() {
        self.`default` = nil
        self.required = nil
        self.disabled = nil
        self.collapse = nil
        self.hidden = nil
        self.role = nil
        self.description = nil
        self.comment = nil
        self.pattern = nil
        self.max = nil
        self.min = nil
        self.step = nil
        self.badges = nil
        self.link = nil
    }
}

// MARK: - settings/update 响应

/// settings/update / replace / mutate 的响应（返回新的命名空间视图）
struct SettingsUpdateResult: Decodable {
    let ns: String
    let revision: Int
    let value: AnyCodable?
}

// MARK: - 值操作工具

/// 基于 AnyCodable 的 JSON 值读写辅助（用于表单编辑）
enum JSONValue {
    /// 取 dict 下某字段；无则返回 nil
    static func get(_ value: AnyCodable?, key: String) -> AnyCodable? {
        value?.objectValue?[key]
    }

    /// 设置 dict 下某字段（保留其他字段）；value 为 nil 时删除字段
    static func set(_ value: AnyCodable?, key: String, to newValue: AnyCodable?) -> AnyCodable? {
        var obj = value?.objectValue ?? [:]
        if let newValue {
            obj[key] = newValue
        } else {
            obj.removeValue(forKey: key)
        }
        return .object(obj)
    }

    /// 深拷贝 AnyCodable（值类型语义）
    static func deepCopy(_ value: AnyCodable?) -> AnyCodable? {
        value
    }
}
