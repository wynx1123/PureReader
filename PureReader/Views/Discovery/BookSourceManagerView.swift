import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct BookSourceManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BookSource.weight, order: .reverse) private var sources: [BookSource]

    @State private var showImporter = false
    @State private var importURLText = ""
    @State private var showURLImport = false
    @State private var message: String?
    @State private var isBusy = false
    @State private var exportURL: URL?
    @State private var validatingID: UUID?
    @State private var showCommunity = false

    /// 可选社区合集（raw JSON），用户确认后从 URL 导入
    private let communityPresets: [(name: String, url: String)] = [
        (
            String(localized: "示例书源合集（需自备有效 JSON）"),
            "https://raw.githubusercontent.com/wynx1123/PureReader/main/docs/sample-sources.json"
        )
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label(String(localized: "从文件导入 JSON"), systemImage: "doc.badge.plus")
                    }
                    Button {
                        showURLImport = true
                    } label: {
                        Label(String(localized: "从 URL 导入"), systemImage: "link")
                    }
                    Button {
                        showCommunity = true
                    } label: {
                        Label(String(localized: "社区书源（URL 预设）"), systemImage: "globe")
                    }
                    Button {
                        exportSources()
                    } label: {
                        Label(String(localized: "导出全部书源"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(sources.isEmpty)

                    Button {
                        Task { await validateAll() }
                    } label: {
                        Label(String(localized: "检测全部书源"), systemImage: "stethoscope")
                    }
                    .disabled(sources.isEmpty || isBusy)
                } footer: {
                    Text(String(localized: "检测会对每个启用书源发起一次试搜索。无效源会标记并关闭。"))
                }

                Section(String(localized: "已安装（\(sources.count)）")) {
                    if sources.isEmpty {
                        Text(String(localized: "暂无书源，请导入 JSON"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sources) { source in
                            sourceRow(source)
                        }
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
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json, .plainText, .data],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert(
                String(localized: "从 URL 导入"),
                isPresented: $showURLImport
            ) {
                TextField("https://…", text: $importURLText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button(String(localized: "取消"), role: .cancel) {}
                Button(String(localized: "导入")) {
                    Task { @MainActor in await importFromURL() }
                }
            } message: {
                Text(String(localized: "粘贴书源 JSON 的 HTTPS 地址"))
            }
            .confirmationDialog(
                String(localized: "社区书源"),
                isPresented: $showCommunity,
                titleVisibility: .visible
            ) {
                ForEach(communityPresets, id: \.url) { preset in
                    Button(preset.name) {
                        importURLText = preset.url
                        Task { await importFromURL() }
                    }
                }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                Text(String(localized: "从公开 HTTPS JSON 导入；无效地址会提示失败。"))
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
            .overlay {
                if isBusy {
                    ProgressView()
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

    @ViewBuilder
    private func sourceRow(_ source: BookSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(.headline)
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
                    Text(source.format.rawValue)
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

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            message = err.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isBusy = true
            defer { isBusy = false }
            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let result = try BookSourceImporter.importJSON(data, into: modelContext)
                message = result.message
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func importFromURL() async {
        guard let url = URL(string: importURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = String(localized: "URL 无效")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await BookSourceImporter.importFromURL(url, into: modelContext)
            message = result.message
        } catch {
            message = error.localizedDescription
        }
    }

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

    @MainActor
    private func validateOne(_ source: BookSource) async {
        validatingID = source.id
        defer { validatingID = nil }
        let ok = await BookSourceEngine.validate(source)
        source.isValid = ok
        if !ok {
            source.enabled = false
            source.comment = String(localized: "检测未通过（试搜索无结果）")
        } else if source.comment.contains("检测未通过") {
            source.comment = ""
        }
        try? modelContext.save()
        message = ok
            ? String(localized: "「\(source.name)」检测通过")
            : String(localized: "「\(source.name)」检测失败，已关闭")
    }

    @MainActor
    private func validateAll() async {
        isBusy = true
        defer { isBusy = false }
        var pass = 0
        var fail = 0
        for source in sources where source.enabled {
            let ok = await BookSourceEngine.validate(source)
            source.isValid = ok
            source.lastCheckedAt = Date()
            if ok {
                pass += 1
            } else {
                fail += 1
                source.enabled = false
            }
        }
        try? modelContext.save()
        message = String(localized: "检测完成：通过 \(pass)，失败 \(fail)")
    }
}

private struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
    init(url: URL) { self.url = url }
}
