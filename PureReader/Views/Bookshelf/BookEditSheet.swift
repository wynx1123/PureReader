import SwiftUI
import SwiftData

/// 分组选择器（编辑书籍 / 添加书籍共用）。
///
/// 列出内置三组 + 用户自定义分组，并提供「新建分组…」入口。
/// 绑定值始终是可以直接写进 `Book.group` 的稳定 key（默认组为 `BuiltInGroup.defaultKey`），
/// 显示名统一走 `BuiltInGroup.displayName(for:)`，用户切换系统语言后选中项也不会对不上。
struct GroupPicker: View {
    @Binding var selection: String
    /// 用户自定义分组（来自 `ShelfPreferences.customGroups`）
    let customGroups: [String]
    /// 创建回调；返回 true 表示确实新建了分组。
    let onCreate: (String) -> Bool

    /// 「新建分组…」在 Picker 里的占位 tag，永远不会被写进 `Book.group`。
    private static let createTag = "__pr_create_group"

    @State private var showCreateAlert = false
    @State private var newGroupName = ""

    /// 内置组在前、自定义组按本地化顺序在后。
    /// 当前选中值即使已从偏好里被删掉也会补进来，否则 Picker 找不到 tag 会显示空白。
    private var options: [String] {
        let builtIn = BuiltInGroup.allKeys
        var seen: Set<String> = Set(builtIn).union([Self.createTag])
        var extras: [String] = []
        for raw in customGroups + [selection] {
            guard let key = BuiltInGroup.normalize(raw), seen.insert(key).inserted else { continue }
            extras.append(key)
        }
        extras.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return builtIn + extras
    }

    /// 把用户输入的名字映射回内置组的稳定 key（输入「默认」「正在读」等显示名时用）。
    private func builtInKey(matching name: String) -> String? {
        if BuiltInGroup.allKeys.contains(name) { return name }
        return BuiltInGroup.allKeys.first { BuiltInGroup.displayName(for: $0) == name }
    }

    /// 选中「新建分组…」只弹输入框，不把占位 tag 写回 selection。
    /// get 侧再归一一次：外部若传进来的是旧版中文名，Picker 才不会因为找不到 tag 而显示空白。
    private var pickerBinding: Binding<String> {
        Binding(
            get: { BuiltInGroup.normalize(selection) ?? BuiltInGroup.defaultKey },
            set: { newValue in
                guard newValue == Self.createTag else {
                    selection = newValue
                    return
                }
                newGroupName = ""
                showCreateAlert = true
            }
        )
    }

    var body: some View {
        Picker(String(localized: "分组"), selection: pickerBinding) {
            ForEach(options, id: \.self) { key in
                Text(BuiltInGroup.displayName(for: key)).tag(key)
            }
            Label(String(localized: "新建分组…"), systemImage: "folder.badge.plus")
                .tag(Self.createTag)
        }
        .alert(String(localized: "新建分组"), isPresented: $showCreateAlert) {
            TextField(String(localized: "分组名称"), text: $newGroupName)
                .textInputAutocapitalization(.never)
            Button(String(localized: "取消"), role: .cancel) { newGroupName = "" }
            Button(String(localized: "创建")) {
                let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                newGroupName = ""
                guard !name.isEmpty else { return }
                // 输入的是内置组名（如「正在读」）时不新建，直接切到对应内置组。
                if let key = builtInKey(matching: name) {
                    selection = key
                    return
                }
                // 已存在同名分组时 onCreate 返回 false，此时同样直接选中它。
                if onCreate(name) || customGroups.contains(name) {
                    selection = name
                }
            }
        } message: {
            Text(String(localized: "分组名称不能为空，也不能与内置分组重名。"))
        }
    }
}

struct BookEditSheet: View {
    @Bindable var book: Book
    /// 由书架传入以复用同一份状态；未传时内部自建一个，仅用于写入自定义分组。
    var viewModel: BookshelfViewModel? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var preferences: [ShelfPreferences]
    @State private var fallbackViewModel = BookshelfViewModel()

    @State private var title: String = ""
    @State private var author: String = ""
    @State private var group: String = BuiltInGroup.defaultKey
    @State private var tagsText: String = ""

    private var groupEditor: BookshelfViewModel { viewModel ?? fallbackViewModel }
    private var customGroups: [String] { preferences.first?.customGroups ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "基本信息")) {
                    TextField(String(localized: "书名"), text: $title)
                    TextField(String(localized: "作者"), text: $author)
                }
                Section(String(localized: "整理")) {
                    GroupPicker(
                        selection: $group,
                        customGroups: customGroups,
                        onCreate: { groupEditor.createGroup($0, context: modelContext) }
                    )
                    TextField(String(localized: "标签（逗号分隔）"), text: $tagsText)
                        .textInputAutocapitalization(.never)
                }
                Section(String(localized: "详情")) {
                    LabeledContent(String(localized: "章节数"), value: "\(book.totalChapters)")
                    LabeledContent(String(localized: "格式"), value: book.format.rawValue.uppercased())
                    LabeledContent(
                        String(localized: "进度"),
                        value: "\(Int(book.progressFraction * 100))%"
                    )
                }
            }
            .navigationTitle(String(localized: "编辑书籍"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存")) {
                        book.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        book.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
                        // normalize 会把默认组归一成 nil，自定义组原样保留。
                        book.group = BuiltInGroup.normalize(group)
                        book.tags = tagsText
                            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" })
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        try? modelContext.save()
                        dismiss()
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .onAppear {
                title = book.title
                author = book.author
                // 此前用的是 groupDisplayName（本地化显示名），与 Picker 的稳定 key 对不上，
                // 打开编辑页时分组会显示为空并在保存时被改写。
                group = BuiltInGroup.normalize(book.group) ?? BuiltInGroup.defaultKey
                tagsText = book.tags.joined(separator: ", ")
            }
        }
    }
}
