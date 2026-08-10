import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

// MARK: - URL Import Sheet

/// 替代已废弃的 `.alert` + `TextField` 方案，提供专用的 URL 输入页面。
private struct BookSourceURLImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    let onImport: (String) async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .disableAutocorrection(true)
                } header: {
                    Text(String(localized: "粘贴书源 JSON 的地址"))
                } footer: {
                    Text(String(localized: "支持 Legado 阅读3.0 / 爱阅记 / PureReader 格式的 JSON 文件。HTTP 连接不会加密。"))
                }

                Section {
                    Text(String(localized: "从哪里获取书源？"))
                        .font(.subheadline.weight(.medium))
                    Text(String(localized: "• 在 GitHub 搜索「Legado 书源」或「阅读3.0 书源」\n• 在酷安、百度贴吧等社区搜索书源合集\n• 从其他阅读 App 导出书源 JSON"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "从 URL 导入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "导入")) {
                        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                        Task { await onImport(trimmed) }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Book Source Detail View

/// 书源详情与编辑页：查看和修改名称、分组、URL、备注，支持删除。
private struct BookSourceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let source: BookSource
    @State private var name: String
    @State private var groupName: String
    @State private var searchURL: String
    @State private var bookURL: String
    @State private var comment: String
    @State private var enabled: Bool
    @State private var showDeleteConfirm = false
    @State private var saveError: String?
    @State private var showHealthCheck = false

    init(source: BookSource) {
        self.source = source
        _name = State(initialValue: source.name)
        _groupName = State(initialValue: source.groupName)
        _searchURL = State(initialValue: source.searchURL)
        _bookURL = State(initialValue: source.bookURL)
        _comment = State(initialValue: source.comment)
        _enabled = State(initialValue: source.enabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "基本信息")) {
                    TextField(String(localized: "名称"), text: $name)
                    TextField(String(localized: "分组"), text: $groupName)
                    Toggle(String(localized: "启用"), isOn: $enabled)
                }

                Section(String(localized: "网络")) {
                    TextField(String(localized: "搜索 URL"), text: $searchURL, axis: .vertical)
                        .font(.caption.monospaced())
                    TextField(String(localized: "书源 URL"), text: $bookURL, axis: .vertical)
                        .font(.caption.monospaced())
                }

                Section(String(localized: "备注")) {
                    TextEditor(text: $comment)
                        .font(.caption)
                        .frame(minHeight: 80)
                }

                Section {
                    LabeledContent(String(localized: "格式")) {
                        Text(source.format.displayName)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(String(localized: "状态")) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(source.isValid ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(source.isValid
                                ? String(localized: "可用")
                                : String(localized: "未检测/不可用"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let lastChecked = source.lastCheckedAt {
                        LabeledContent(String(localized: "上次检测")) {
                            Text(lastChecked, style: .date)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        showHealthCheck = true
                    } label: {
                        Label(String(localized: "完整检测"), systemImage: "stethoscope.circle")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(String(localized: "删除书源"), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(String(localized: "书源详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存")) {
                        source.name = name
                        source.groupName = groupName
                        source.searchURL = searchURL
                        source.bookURL = bookURL
                        source.comment = comment
                        source.enabled = enabled
                        do {
                            try modelContext.save()
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                }
            }
            .confirmationDialog(
                String(localized: "确认删除"),
                isPresented: $showDeleteConfirm
            ) {
                Button(String(localized: "删除"), role: .destructive) {
                    modelContext.delete(source)
                    do {
                        try modelContext.save()
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                Text(String(localized: "确定要删除书源「\(source.name)」吗？此操作不可撤销。"))
            }
            .alert(
                String(localized: "保存失败"),
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button(String(localized: "好"), role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
            .sheet(isPresented: $showHealthCheck) {
                BookSourceHealthView(source: source)
            }
        }
    }
}

// MARK: - Main Manager View

struct BookSourceManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BookSource.weight, order: .reverse) private var sources: [BookSource]

    @State private var showImporter = false
    @State private var showURLImportSheet = false
    @State private var importURLText = ""
    @State private var message: String?
    @State private var isBusy = false
    @State private var exportURL: URL?
    @State private var validatingID: UUID?
    @State private var showCommunity = false
    @State private var detailSource: BookSource?
    @State private var busyDetail: String = ""

    /// 社区推荐书源合集
    private let communityPresets: [(name: String, url: String)] = [
        (
            String(localized: "PureReader 验证书源"),
            "https://cdn.jsdelivr.net/gh/wynx1123/PureReader@develop/docs/sample-sources.json"
        )
    ]

    var body: some View {
        NavigationStack {
            List {
                // MARK: Import / Export
                Section {
                    Button {
                        importBuiltinSources()
                    } label: {
                        Label(String(localized: "安装内置书源"), systemImage: "shippingbox")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label(String(localized: "从文件导入 JSON"), systemImage: "doc.badge.plus")
                    }
                    Button {
                        showURLImportSheet = true
                    } label: {
                        Label(String(localized: "从 URL 导入"), systemImage: "link")
                    }
                    Button {
                        showCommunity = true
                    } label: {
                        Label(String(localized: "从社区导入"), systemImage: "globe")
                    }
                    Button {
                        exportSources()
                    } label: {
                        Label(String(localized: "导出全部书源"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(sources.isEmpty)
                } header: {
                    Text(String(localized: "导入与导出"))
                } footer: {
                    Text(String(localized: "支持 Legado 阅读3.0、爱阅记和 PureReader 格式的 JSON 书源。重复导入同一合集会更新现有书源，不会重复创建。"))
                }

                // MARK: Validation
                Section {
                    Button {
                        Task { await validateAll() }
                    } label: {
                        Label(String(localized: "检测全部书源"), systemImage: "stethoscope")
                    }
                    .disabled(sources.isEmpty || isBusy)
                } footer: {
                    Text(String(localized: "对每个启用书源发起一次试搜索，验证其可用性。请求成功但无结果时保持启用，只有请求失败才标记为不可用。"))
                }

                // MARK: Source list
                Section {
                    if sources.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text(String(localized: "暂无书源"))
                                .font(.headline)
                            Text(String(localized: "请从文件、URL 或社区导入书源 JSON 来开始使用。「发现」页面的搜索和书库功能需要书源才能正常工作。"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        ForEach(sources) { source in
                            sourceRow(source)
                        }
                    }
                } header: {
                    Text(String(localized: "已安装（\(sources.count)）"))
                } footer: {
                    if !sources.isEmpty {
                        Text(String(localized: "左滑可检测单个书源，右滑可删除。点击可查看和编辑详情。"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(String(localized: "书源管理"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            // MARK: Sheets
            .sheet(isPresented: $showImporter) {
                BookSourceDocumentPicker(
                    allowedContentTypes: [.json],
                    allowsMultipleSelection: false
                ) { urls in
                    showImporter = false
                    handleImport(.success(urls))
                } onCancel: {
                    showImporter = false
                }
            }
            .sheet(isPresented: $showURLImportSheet) {
                BookSourceURLImportSheet { text in
                    importURLText = text
                    await importFromURL()
                }
            }
            .sheet(item: $detailSource) { source in
                BookSourceDetailView(source: source)
            }
            // MARK: Dialogs
            .confirmationDialog(
                String(localized: "从社区导入"),
                isPresented: $showCommunity,
                titleVisibility: .visible
            ) {
                ForEach(communityPresets, id: \.url) { preset in
                    Button(preset.name) {
                        importURLText = preset.url
                        Task { await importFromURL() }
                    }
                }
                Button(String(localized: "手动输入 URL")) {
                    showCommunity = false
                    showURLImportSheet = true
                }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                Text(String(localized: "选择一个社区维护的书源合集。导入后可在列表中查看和启用。"))
            }
            .alert(
                String(localized: "提示"),
                isPresented: Binding(
                    get: { message != nil },
                    set: { if !$0 { message = nil } }
                )
            ) {
                Button(String(localized: "好"), role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            // MARK: Busy overlay
            .overlay {
                if isBusy {
                    VStack(spacing: 12) {
                        ProgressView()
                        if !busyDetail.isEmpty {
                            Text(busyDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(item: Binding(
                get: { exportURL.map(ExportItem.init) },
                set: { exportURL = $0?.url }
            )) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    // MARK: - Source Row

    @ViewBuilder
    private func sourceRow(_ source: BookSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Circle()
                        .fill(source.isValid ? Color.green.opacity(0.8) : Color.orange.opacity(0.8))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(
                            source.isValid
                                ? String(localized: "有效")
                                : String(localized: "无效或未检测")
                        )
                }
                HStack(spacing: 8) {
                    if !source.groupName.isEmpty {
                        Text(source.groupName)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Text(source.format.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !source.comment.isEmpty {
                    Text(source.comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if validatingID == source.id {
                ProgressView()
            }
            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { source.enabled = $0; try? modelContext.save() }
            ))
            .labelsHidden()
            .frame(minWidth: 44, minHeight: 44)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            detailSource = source
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                Task { await validateOne(source) }
            } label: {
                Label(String(localized: "检测"), systemImage: "stethoscope")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                modelContext.delete(source)
                try? modelContext.save()
            } label: {
                Label(String(localized: "删除"), systemImage: "trash")
            }
        }
    }

    // MARK: - Import

    private func importBuiltinSources() {
        do {
            let outcome = try BookSourceImporter.importBuiltinSources(into: modelContext)
            message = outcome.message
        } catch {
            message = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            let nsError = err as NSError
            // 用户取消选择不算失败。
            guard nsError.code != NSUserCancelledError else { return }
            message = err.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                message = String(localized: "请选择 JSON 文件，不能选择文件夹")
                return
            }
            // 在文件选择回调当下取得 scope，文件读取放到后台，
            // 避免大合集在主线程上做 IO + JSON 解析。
            let accessed = url.startAccessingSecurityScopedResource()
            isBusy = true
            busyDetail = String(localized: "正在解析书源文件…")
            Task {
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    isBusy = false
                    busyDetail = ""
                }
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try BookSourceImporter.readLocalJSON(from: url)
                    }.value
                    let outcome = try BookSourceImporter.importJSON(data, into: modelContext)
                    message = outcome.message
                } catch {
                    message = error.localizedDescription
                }
            }
        }
    }

    private func importFromURL() async {
        guard let url = URL(string: importURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = String(localized: "URL 无效，请输入完整的 HTTP/HTTPS 地址")
            return
        }
        isBusy = true
        busyDetail = String(localized: "正在下载并解析书源…")
        defer {
            isBusy = false
            busyDetail = ""
        }
        do {
            let result = try await BookSourceImporter.importFromURL(url, into: modelContext)
            message = result.message
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Export

    private func exportSources() {
        do {
            let data = try BookSourceImporter.exportJSON(sources: sources)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PureReader-sources-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Validation

    @MainActor
    private func validateOne(_ source: BookSource) async {
        validatingID = source.id
        defer { validatingID = nil }
        let result = await BookSourceEngine.validateDetailed(source)
        source.isValid = result.isReachable
        source.lastCheckedAt = Date()
        if !result.isReachable {
            source.enabled = false
            appendDetectionNote(to: source, message: result.message)
        } else if source.comment.contains(Self.detectionStartMarker) {
            // 清除之前的检测失败备注，但保留用户原始备注
            removeDetectionNotes(from: source)
        }
        try? modelContext.save()
        message = result.isReachable
            ? String(localized: "「\(source.name)」\(result.message)")
            : String(localized: "「\(source.name)」检测失败，已关闭：\(result.message)")
    }

    @MainActor
    private func validateAll() async {
        isBusy = true
        busyDetail = String(localized: "正在并发检测书源…")
        defer {
            isBusy = false
            busyDetail = ""
        }
        let enabledSources = sources.filter { $0.enabled }
        guard !enabledSources.isEmpty else {
            message = String(localized: "没有启用的书源可供检测")
            return
        }

        var pass = 0
        var fail = 0

        // 使用 TaskGroup 并发检测，而非串行逐个等待
        await withTaskGroup(of: (UUID, BookSourceValidationResult).self) { group in
            for source in enabledSources {
                group.addTask {
                    let result = await BookSourceEngine.validateDetailed(source)
                    return (source.id, result)
                }
            }
            for await (sourceID, result) in group {
                guard let source = sources.first(where: { $0.id == sourceID }) else { continue }
                source.isValid = result.isReachable
                source.lastCheckedAt = Date()
                if result.isReachable {
                    pass += 1
                    if source.comment.contains(Self.detectionStartMarker) {
                        removeDetectionNotes(from: source)
                    }
                } else {
                    fail += 1
                    source.enabled = false
                    appendDetectionNote(to: source, message: result.message)
                }
                busyDetail = String(localized: "已检测 \(pass + fail) / \(enabledSources.count)")
            }
        }
        try? modelContext.save()
        message = String(localized: "检测完成：通过 \(pass)，失败 \(fail)")
    }

    // MARK: - Comment helpers

    private static let detectionStartMarker = "\n\n---\n"
    private static let detectionEndMarker = "\n---"

    /// 追加检测备注，使用明确标记分隔，不覆盖用户原有备注。
    private func appendDetectionNote(to source: BookSource, message: String) {
        let note = Self.detectionStartMarker
            + String(localized: "检测未通过：\(message)")
            + Self.detectionEndMarker

        // 先移除旧检测备注
        removeDetectionNotes(from: source)

        if source.comment.isEmpty {
            source.comment = note
        } else {
            source.comment = source.comment.trimmingCharacters(in: .whitespacesAndNewlines) + note
        }
    }

    /// 移除检测备注，只删除标记之间的内容，保留用户原始备注。
    private func removeDetectionNotes(from source: BookSource) {
        guard let startRange = source.comment.range(of: Self.detectionStartMarker) else { return }
        let afterStart = source.comment[startRange.lowerBound...]
        guard let endRange = afterStart.range(of: Self.detectionEndMarker) else {
            // 只有开始标记没有结束标记，移除从开始标记到末尾
            source.comment = String(source.comment[..<startRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        // 移除开始标记到结束标记（含结束标记）之间的全部内容
        let before = String(source.comment[..<startRange.lowerBound])
        let after = String(afterStart[endRange.upperBound...])
        source.comment = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Document Picker

private struct BookSourceDocumentPicker: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
    init(url: URL) { self.url = url }
}