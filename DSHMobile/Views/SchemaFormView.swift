// ============================================================================
//  SchemaFormView.swift — 通用 schema 驱动设置表单
//  ----------------------------------------------------------------------------
//  根据 schemastery 节点类型渲染编辑控件：
//    string  → TextField
//    number  → Stepper（带 min/max/step）
//    boolean → Toggle
//    const   → 只读固定值（展示）
//    union   → Picker（const 成员成为选项；标量成员决定值类型）
//    object  → 分组渲染 dict 字段
//    array   → 列表（增删元素，按 inner 渲染）
//    dict    → 键值表（增删条目，sKey 约束键，inner 渲染值）
//    any     → JSON 文本编辑器（宽松解析）
//
//  绑定方式：不直接持有 AnyCodable 副本，而是通过 (get, set) 闭包按
//  "键路径" 读写工作副本 —— 视图层只描述路径，值存于 SettingsViewModel。
// ============================================================================
import SwiftUI

// MARK: - 值路径工具（基于 JSONValue 的 get/set）

/// 键路径上的一步
enum PathStep {
    case key(String)
    case index(Int)
}

/// 在 AnyCodable 上按路径取值（nil 表示路径不存在）
func valueAt(_ root: AnyCodable?, _ steps: [PathStep]) -> AnyCodable? {
    var current = root
    for step in steps {
        switch step {
        case .key(let k):
            current = current?.objectValue?[k]
        case .index(let i):
            current = current?.arrayValue?[i]
        }
    }
    return current
}

/// 在 AnyCodable 上按路径设值（自动补中间对象/数组）
func setValueAt(_ root: inout AnyCodable?, _ steps: [PathStep], to newValue: AnyCodable?) {
    guard let first = steps.first else {
        root = newValue
        return
    }
    var current = root
    switch first {
    case .key(let k):
        var obj = current?.objectValue ?? [:]
        if steps.count == 1 {
            if let newValue { obj[k] = newValue } else { obj.removeValue(forKey: k) }
        } else {
            var child = obj[k]
            setValueAt(&child, Array(steps.dropFirst()), to: newValue)
            obj[k] = child ?? .null
        }
        root = .object(obj)
    case .index(let i):
        var arr = current?.arrayValue ?? []
        if steps.count == 1 {
            if let newValue {
                while arr.count <= i { arr.append(.null) }
                arr[i] = newValue
            } else if i < arr.count {
                arr.remove(at: i)
            }
        } else {
            while arr.count <= i { arr.append(.null) }
            var child: AnyCodable? = arr[i]
            setValueAt(&child, Array(steps.dropFirst()), to: newValue)
            arr[i] = child ?? .null
        }
        root = .array(arr)
    }
}

// MARK: - 命名空间表单

/// 一个命名空间的完整表单（对象根节点）
struct SchemaFormView: View {
    let namespace: SettingsNamespaceView
    @ObservedObject var viewModel: SettingsViewModel

    @State private var pendingSave = false
    @State private var saveError: String?

    var body: some View {
        let root = namespace.schema?.root
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let root, root.type == "object", let dict = root.dict {
                    let path: [PathStep] = []
                    ForEach(Array(dict.keys).sorted(), id: \.self) { key in
                        if let childUid = dict[key], let child = namespace.schema?.node(childUid) {
                            SchemaFieldView(
                                key: key,
                                node: child,
                                schema: namespace.schema,
                                value: valueAt(viewModel.workingValue(for: namespace.ns), path + [.key(key)]),
                                setValue: { newVal in
                                    var working = viewModel.workingValue(for: namespace.ns)
                                    setValueAt(&working, path + [.key(key)], to: newVal)
                                    viewModel.setWorkingValue(working, for: namespace.ns)
                                }
                            )
                        }
                    }
                } else {
                    // 非 object 根（any 等）：JSON 编辑器兜底
                    JSONEditorView(
                        title: namespace.ns,
                        value: viewModel.workingValue(for: namespace.ns),
                        setValue: { newVal in
                            viewModel.setWorkingValue(newVal, for: namespace.ns)
                        }
                    )
                }

                // 保存区
                VStack(alignment: .leading, spacing: 8) {
                    if pendingSave {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("保存中…")
                        }
                        .foregroundStyle(.secondary)
                    }
                    if let saveError {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button {
                        save()
                    } label: {
                        Label("保存设置", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pendingSave)
                }
            }
            .padding()
        }
        .navigationTitle(namespace.displayName)
    }

    private func save() {
        pendingSave = true
        saveError = nil
        Task { @MainActor in
            do {
                try await viewModel.save(ns: namespace.ns)
            } catch {
                saveError = error.localizedDescription
            }
            pendingSave = false
        }
    }
}

// MARK: - 递归字段视图

/// 单个字段的递归渲染
struct SchemaFieldView: View {
    let key: String
    let node: SchemaNode
    let schema: SchemaDoc?
    let value: AnyCodable?
    let setValue: (AnyCodable?) -> Void

    @State private var expanded = true

    var body: some View {
        // hidden 字段不渲染
        if node.metaOrEmpty.hidden == true {
            EmptyView()
        } else {
            fieldContent
        }
    }

    @ViewBuilder
    private var fieldContent: some View {
        switch node.type {
        case "string":
            StringField(key: key, node: node, value: value?.stringValue ?? "", setValue: { s in
                setValue(.string(s))
            })
        case "number":
            NumberField(key: key, node: node, value: value?.numberValue, setValue: { n in
                setValue(.number(n))
            })
        case "boolean":
            BooleanField(key: key, node: node, value: value?.boolValue ?? false, setValue: { b in
                setValue(.bool(b))
            })
        case "const":
            if let value {
                ConstField(key: key, value: value)
            }
        case "union":
            UnionField(key: key, node: node, schema: schema, value: value, setValue: setValue)
        case "object":
            ObjectField(key: key, node: node, schema: schema, value: value, setValue: setValue, expanded: $expanded)
        case "array":
            ArrayField(key: key, node: node, schema: schema, value: value, setValue: setValue)
        case "dict":
            DictField(key: key, node: node, schema: schema, value: value, setValue: setValue)
        default:
            // any 或其他：JSON 编辑器
            JSONInlineEditor(key: key, value: value, setValue: setValue)
        }
    }
}

// MARK: - 标量字段

struct StringField: View {
    let key: String
    let node: SchemaNode
    let value: String
    let setValue: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(key) {
                TextField("", text: Binding(get: { value }, set: { setValue($0) }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }
            if let desc = node.metaOrEmpty.description ?? node.metaOrEmpty.comment {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct NumberField: View {
    let key: String
    let node: SchemaNode
    let value: Double?
    let setValue: (Double) -> Void

    var body: some View {
        let min = node.metaOrEmpty.min
        let max = node.metaOrEmpty.max
        let step = node.metaOrEmpty.step ?? 1
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key)
                Spacer()
                Stepper(value: Binding(
                    get: { value ?? (node.metaOrEmpty.defaultValue?.numberValue ?? 0) },
                    set: { setValue($0) }
                ), in: (min ?? -1_000_000)...(max ?? 1_000_000), step: step) {
                    Text(formatNumber(value ?? (node.metaOrEmpty.defaultValue?.numberValue ?? 0)))
                        .monospacedDigit()
                }
            }
            if let desc = node.metaOrEmpty.description ?? node.metaOrEmpty.comment {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func formatNumber(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 { return String(Int(n)) }
        return String(format: "%.2f", n)
    }
}

struct BooleanField: View {
    let key: String
    let node: SchemaNode
    let value: Bool
    let setValue: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(key, isOn: Binding(get: { value }, set: { setValue($0) }))
            if let desc = node.metaOrEmpty.description ?? node.metaOrEmpty.comment {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ConstField: View {
    let key: String
    let value: AnyCodable

    var body: some View {
        HStack {
            Text(key)
            Spacer()
            Text(anyCodableDisplay(value) ?? "")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - union（Picker）

struct UnionField: View {
    let key: String
    let node: SchemaNode
    let schema: SchemaDoc?
    let value: AnyCodable?
    let setValue: (AnyCodable?) -> Void

    var body: some View {
        let members = (node.list ?? []).compactMap { schema?.node($0) }
        // 枚举式 union：全部成员都是 const → Picker
        if !members.isEmpty, members.allSatisfy({ $0.type == "const" }) {
            enumPicker(members: members)
        } else {
            // 混合 union：优先取第一个标量成员类型渲染，其余忽略（常见如 string|number）
            mixedFallback(members: members)
        }
    }

    @ViewBuilder
    private func enumPicker(members: [SchemaNode]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(key, selection: Binding(
                get: {
                    anyCodableDisplay(value ?? node.metaOrEmpty.defaultValue) ?? members.first?.value.flatMap(anyCodableDisplay) ?? ""
                },
                set: { label in
                    if let m = members.first(where: { anyCodableDisplay($0.value) == label }) {
                        setValue(m.value)
                    }
                }
            )) {
                ForEach(members.indices, id: \.self) { i in
                    let m = members[i]
                    let label = anyCodableDisplay(m.value) ?? "?"
                    Text(label).tag(label)
                }
            }
            if let desc = node.metaOrEmpty.description ?? node.metaOrEmpty.comment {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func mixedFallback(members: [SchemaNode]) -> some View {
        // 取第一个非 const 成员作为值类型
        if let first = members.first(where: { $0.type != "const" }) {
            SchemaFieldView(
                key: key,
                node: first,
                schema: schema,
                value: value,
                setValue: setValue
            )
        } else {
            JSONInlineEditor(key: key, value: value, setValue: setValue)
        }
    }
}

// MARK: - object（分组）

struct ObjectField: View {
    let key: String
    let node: SchemaNode
    let schema: SchemaDoc?
    let value: AnyCodable?
    let setValue: (AnyCodable?) -> Void
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let dict = node.dict {
                let base: [PathStep] = []
                // 注意：子字段的 set 必须基于父对象值，这里 value 就是本对象
                ForEach(Array(dict.keys).sorted(), id: \.self) { fieldKey in
                    if let childUid = dict[fieldKey], let child = schema?.node(childUid) {
                        SchemaFieldView(
                            key: fieldKey,
                            node: child,
                            schema: schema,
                            value: valueAt(value, base + [.key(fieldKey)]),
                            setValue: { newVal in
                                var obj = value
                                setValueAt(&obj, base + [.key(fieldKey)], to: newVal)
                                setValue(obj)
                            }
                        )
                    }
                }
            }
        } label: {
            HStack {
                Text(key)
                Spacer()
                Text("对象").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - array（列表）

struct ArrayField: View {
    let key: String
    let node: SchemaNode
    let schema: SchemaDoc?
    let value: AnyCodable?
    let setValue: (AnyCodable?) -> Void

    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                let items = value?.arrayValue ?? []
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top) {
                        if let innerUid = node.inner, let inner = schema?.node(innerUid) {
                            SchemaFieldView(
                                key: "\(key)[\(i)]",
                                node: inner,
                                schema: schema,
                                value: items[i],
                                setValue: { newVal in
                                    var arr = value
                                    setValueAt(&arr, [.index(i)], to: newVal)
                                    setValue(arr)
                                }
                            )
                            .frame(maxWidth: .infinity)
                        }
                        Button {
                            var arr = value
                            setValueAt(&arr, [.index(i)], to: nil)
                            setValue(arr)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
                Button {
                    var arr = value
                    // 追加一个默认值元素
                    let defaultVal = defaultValue(for: node.inner, schema: schema)
                    setValueAt(&arr, [.index(items.count)], to: defaultVal)
                    setValue(arr)
                } label: {
                    Label("添加", systemImage: "plus.circle.fill")
                }
            }
        } label: {
            HStack {
                Text(key)
                Spacer()
                Text("列表 (\(value?.arrayValue?.count ?? 0))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func defaultValue(for uid: Int?, schema: SchemaDoc?) -> AnyCodable {
        guard let uid, let n = schema?.node(uid) else { return .null }
        switch n.type {
        case "string": return .string(n.metaOrEmpty.defaultValue?.stringValue ?? "")
        case "number": return .number(n.metaOrEmpty.defaultValue?.numberValue ?? 0)
        case "boolean": return .bool(n.metaOrEmpty.defaultValue?.boolValue ?? false)
        case "const": return n.value ?? .null
        case "object": return .object([:])
        case "array": return .array([])
        case "dict": return .object([:])
        default: return n.metaOrEmpty.defaultValue ?? .null
        }
    }
}

// MARK: - dict（键值表）

struct DictField: View {
    let key: String
    let node: SchemaNode
    let schema: SchemaDoc?
    let value: AnyCodable?
    let setValue: (AnyCodable?) -> Void

    @State private var expanded = true
    @State private var newKey = ""

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                let entries = value?.objectValue ?? [:]
                ForEach(Array(entries.keys).sorted(), id: \.self) { entryKey in
                    HStack(alignment: .top) {
                        if let innerUid = node.inner, let inner = schema?.node(innerUid) {
                            SchemaFieldView(
                                key: entryKey,
                                node: inner,
                                schema: schema,
                                value: entries[entryKey],
                                setValue: { newVal in
                                    var obj = value
                                    setValueAt(&obj, [.key(entryKey)], to: newVal)
                                    setValue(obj)
                                }
                            )
                            .frame(maxWidth: .infinity)
                        }
                        Button {
                            var obj = value
                            setValueAt(&obj, [.key(entryKey)], to: nil)
                            setValue(obj)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
                HStack {
                    TextField("新键名", text: $newKey)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("添加") {
                        guard !newKey.isEmpty else { return }
                        var obj = value
                        let defaultVal = defaultValue(for: node.inner, schema: schema)
                        setValueAt(&obj, [.key(newKey)], to: defaultVal)
                        setValue(obj)
                        newKey = ""
                    }
                    .disabled(newKey.isEmpty)
                }
            }
        } label: {
            HStack {
                Text(key)
                Spacer()
                Text("映射 (\(value?.objectValue?.count ?? 0))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func defaultValue(for uid: Int?, schema: SchemaDoc?) -> AnyCodable {
        guard let uid, let n = schema?.node(uid) else { return .null }
        switch n.type {
        case "string": return .string(n.metaOrEmpty.defaultValue?.stringValue ?? "")
        case "number": return .number(n.metaOrEmpty.defaultValue?.numberValue ?? 0)
        case "boolean": return .bool(n.metaOrEmpty.defaultValue?.boolValue ?? false)
        case "const": return n.value ?? .null
        case "object": return .object([:])
        case "array": return .array([])
        default: return n.metaOrEmpty.defaultValue ?? .null
        }
    }
}

// MARK: - JSON 编辑兜底

/// 整对象 JSON 编辑器（非 object 根 / any）
struct JSONEditorView: View {
    let title: String
    let value: AnyCodable?
    let setValue: (AnyCodable?) -> Void

    @State private var text: String = ""
    @State private var parseError: String?
    @State private var inited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: text) {
                    if let data = text.data(using: .utf8) {
                        if let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data) {
                            parseError = nil
                            setValue(decoded)
                        } else {
                            parseError = "JSON 解析失败"
                        }
                    }
                }
            if let parseError {
                Text(parseError).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear {
            guard !inited else { return }
            inited = true
            text = prettyJSON(value)
        }
    }
}

/// 行内 JSON 编辑器（any 字段）
struct JSONInlineEditor: View {
    let key: String
    let value: AnyCodable?
    let setValue: (AnyCodable?) -> Void

    @State private var text: String = ""
    @State private var inited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key).font(.subheadline)
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: text) {
                    if let data = text.data(using: .utf8) {
                        if let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data) {
                            setValue(decoded)
                        }
                    }
                }
        }
        .onAppear {
            guard !inited else { return }
            inited = true
            text = prettyJSON(value)
        }
    }
}

// MARK: - 工具

/// AnyCodable → 显示文本
func anyCodableDisplay(_ v: AnyCodable?) -> String? {
    guard let v else { return nil }
    switch v {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n):
        if n == n.rounded() && abs(n) < 1e15 { return String(Int(n)) }
        return String(format: "%.2f", n)
    case .string(let s): return s
    case .array(let a): return a.compactMap(anyCodableDisplay).joined(separator: ", ")
    case .object(let o): return o.keys.sorted().joined(separator: ", ")
    }
}

/// AnyCodable → 紧凑 JSON 文本（含 null 时返回空对象）
func prettyJSON(_ v: AnyCodable?) -> String {
    guard let v else { return "{}" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(v) else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
}
