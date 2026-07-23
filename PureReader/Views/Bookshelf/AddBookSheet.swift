import SwiftUI

/// 添加书籍：触发根视图上的 fileImporter / URL sheet（不在此嵌套文件选择器）
struct AddBookSheet: View {
    @Bindable var viewModel: BookshelfViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        dismiss()
                        // 等 sheet 关闭后再弹文件选择器，避免 iOS 冲突
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            viewModel.showImporter = true
                        }
                    } label: {
                        Label(String(localized: "从文件导入 TXT / EPUB"), systemImage: "doc.badge.plus")
                            .frame(minHeight: PRTheme.touch)
                    }

                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            viewModel.showURLImporter = true
                        }
                    } label: {
                        Label(String(localized: "从 HTTPS 链接导入"), systemImage: "link")
                            .frame(minHeight: PRTheme.touch)
                    }
                } header: {
                    Text(String(localized: "导入方式"))
                } footer: {
                    Text(String(localized: "文件选择器在主界面打开，可多选。支持 UTF-8 / GBK TXT 与标准 EPUB。"))
                }

                Section(String(localized: "元数据（导入后应用）")) {
                    Picker(String(localized: "分组"), selection: $viewModel.pendingGroup) {
                        ForEach(BuiltInGroup.all, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    TextField(
                        String(localized: "标签（逗号分隔）"),
                        text: $viewModel.pendingTags
                    )
                    .textInputAutocapitalization(.never)
                }

                if viewModel.isImporting {
                    Section {
                        HStack {
                            ProgressView()
                            Text(String(localized: "正在导入…"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "添加书籍"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                        .frame(minWidth: PRTheme.touch, minHeight: PRTheme.touch)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct URLImportSheet: View {
    @Bindable var viewModel: BookshelfViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $viewModel.urlString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } footer: {
                    Text(String(localized: "仅支持 HTTPS 直链的 TXT / EPUB"))
                }

                if viewModel.isImporting {
                    HStack {
                        ProgressView()
                        Text(String(localized: "下载并解析中…"))
                    }
                }

                if let err = viewModel.importErrorMessage {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            .navigationTitle(String(localized: "链接导入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) {
                        viewModel.importErrorMessage = nil
                        dismiss()
                    }
                        .frame(minWidth: PRTheme.touch, minHeight: PRTheme.touch)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "导入")) {
                        Task {
                            await viewModel.importFromURL(context: modelContext)
                            if viewModel.importErrorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        viewModel.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.isImporting
                    )
                    .frame(minWidth: PRTheme.touch, minHeight: PRTheme.touch)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            viewModel.importErrorMessage = nil
        }
        .onDisappear {
            if viewModel.importSuccessMessage == nil {
                viewModel.importErrorMessage = nil
            }
        }
    }
}
