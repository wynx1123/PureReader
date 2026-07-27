import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 整库备份与恢复。
///
/// 数据纯本地且关闭了 CloudKit，换机或重装等于书架清零 —— 这里是唯一的找回途径。
struct BackupView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var overview = LibraryOverview()
    @State private var includeCovers = true

    @State private var progress: BackupProgress?
    @State private var isBusy = false

    @State private var backupFile: BackupFile?
    @State private var showShareSheet = false

    @State private var showImporter = false
    @State private var pendingRestore: PendingRestore?

    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            overviewSection
            backupSection
            restoreSection
            noticeSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "备份与恢复"))
        .navigationBarTitleDisplayMode(.inline)
        // 用 allowsHitTesting 而不是 disabled：后者会把 isEnabled 一路传进 sheet，
        // 让恢复方式选择页里的按钮跟着变灰。
        .allowsHitTesting(!isBusy)
        .task { refreshOverview() }
        .onChange(of: includeCovers) { _, _ in refreshOverview() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: BackupService.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handlePickedBackup(result)
        }
        .sheet(isPresented: $showShareSheet) {
            if let backupFile {
                ShareSheet(items: [backupFile.url])
            }
        }
        .sheet(item: $pendingRestore) { pending in
            RestoreOptionsSheet(
                pending: pending,
                currentBookCount: overview.bookCount,
                onConfirm: { strategy in runRestore(pending.archive, strategy: strategy) },
                onCancel: { pendingRestore = nil }
            )
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
        .alert(
            String(localized: "出错了"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay { busyOverlay }
    }

    // MARK: - 书库概况

    private var overviewSection: some View {
        Section {
            LabeledContent(String(localized: "书籍"), value: String(localized: "\(overview.bookCount) 本"))
            LabeledContent(String(localized: "章节"), value: String(localized: "\(overview.chapterCount) 章"))
            LabeledContent(
                String(localized: "阅读记录"),
                value: String(localized: "\(overview.readingRecordCount) 条")
            )
            LabeledContent(
                String(localized: "累计阅读"),
                value: formatDuration(overview.totalReadingSeconds)
            )
            if overview.bookmarkCount > 0 {
                LabeledContent(
                    String(localized: "书签与划线"),
                    value: String(localized: "\(overview.bookmarkCount) 条")
                )
            }
            if overview.rewriteCount > 0 {
                LabeledContent(
                    String(localized: "AI 改写记录"),
                    value: String(localized: "\(overview.rewriteCount) 条")
                )
            }
            if overview.sourceCount > 0 {
                LabeledContent(
                    String(localized: "书源"),
                    value: String(localized: "\(overview.sourceCount) 个")
                )
            }
            LabeledContent(
                String(localized: "预计备份体积"),
                value: String(localized: "约 \(BackupService.formatBytes(overview.estimatedBytes))")
            )
        } header: {
            Text(String(localized: "当前书库"))
        } footer: {
            Text(String(localized: "体积为抽样估算，实际文件大小可能有出入。"))
        }
    }

    // MARK: - 备份

    private var backupSection: some View {
        Section {
            Toggle(String(localized: "包含封面图"), isOn: $includeCovers)

            Button {
                runBackup()
            } label: {
                Label(String(localized: "立即备份"), systemImage: "arrow.up.doc")
            }
            .disabled(overview.isEmpty)

            if let backupFile {
                Button {
                    showShareSheet = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            String(localized: "再次分享刚生成的备份"),
                            systemImage: "square.and.arrow.up"
                        )
                        Text(backupFile.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(String(localized: "备份"))
        } footer: {
            Text(String(
                localized: "备份会打包全部书籍正文、阅读进度、时长记录、书签、AI 改写历史与书源，生成一个 .purereaderbackup 文件。请存到「文件」App、iCloud 云盘或发给自己，重装后即可恢复。关闭封面图可显著减小体积。"
            ))
        }
    }

    // MARK: - 恢复

    private var restoreSection: some View {
        Section {
            Button {
                showImporter = true
            } label: {
                Label(String(localized: "从备份恢复"), systemImage: "arrow.down.doc")
            }
        } header: {
            Text(String(localized: "恢复"))
        } footer: {
            Text(String(
                localized: "选择备份文件后可以决定「合并」还是「完全覆盖」。恢复在单个事务内完成，中途失败会自动回滚，不会留下导了一半的书库。"
            ))
        }
    }

    private var noticeSection: some View {
        Section {
            Label(
                String(localized: "AI 与语音的 API Key 保存在系统钥匙串，出于安全考虑不会写进备份文件，恢复后需要重新填写。"),
                systemImage: "key.slash"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Label(
                String(localized: "全书理解的向量索引与记忆锚点属于可再生数据，同样不进备份，恢复后会按需重建。"),
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text(String(localized: "不会被备份的内容"))
        }
    }

    // MARK: - 进度浮层

    @ViewBuilder
    private var busyOverlay: some View {
        if isBusy {
            VStack(spacing: 12) {
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                } else {
                    ProgressView()
                }
                Text(progress?.stage.text ?? String(localized: "处理中…"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let progress, progress.total > 0 {
                    Text("\(progress.completed) / \(progress.total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 8, y: 2)
        }
    }

    // MARK: - 动作

    private func refreshOverview() {
        overview = BackupService.overview(
            context: modelContext,
            options: BackupOptions(includeCovers: includeCovers)
        )
    }

    private func runBackup() {
        isBusy = true
        progress = BackupProgress(stage: .reading)
        Task {
            defer {
                isBusy = false
                progress = nil
            }
            do {
                let file = try await BackupService.exportBackup(
                    context: modelContext,
                    options: BackupOptions(includeCovers: includeCovers),
                    progress: { progress = $0 }
                )
                backupFile = file
                // 直接弹分享，不再弹 alert —— alert 与 sheet 同时出现会互相抢占。
                // 结果摘要显示在下方「分享最近一次备份」那一行。
                showShareSheet = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handlePickedBackup(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            let nsError = error as NSError
            // 用户主动取消不算失败。
            guard nsError.code != NSUserCancelledError else { return }
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // 在回调当下取得安全作用域，读取与解码放到后台。
            let accessed = url.startAccessingSecurityScopedResource()
            isBusy = true
            progress = BackupProgress(stage: .decoding)
            Task {
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    isBusy = false
                    progress = nil
                }
                do {
                    let archive = try await BackupService.loadArchive(from: url)
                    pendingRestore = PendingRestore(archive: archive, filename: url.lastPathComponent)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func runRestore(_ archive: BackupArchive, strategy: RestoreStrategy) {
        pendingRestore = nil
        isBusy = true
        progress = BackupProgress(stage: .applying)
        Task {
            defer {
                isBusy = false
                progress = nil
            }
            do {
                let result = try await BackupService.restore(
                    archive,
                    strategy: strategy,
                    into: modelContext,
                    progress: { progress = $0 }
                )
                refreshOverview()
                message = result.message
            } catch {
                refreshOverview()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return String(localized: "\(hours) 小时 \(minutes) 分")
        }
        return String(localized: "\(minutes) 分")
    }
}

// MARK: - 待恢复的备份

private struct PendingRestore: Identifiable {
    let id = UUID()
    let archive: BackupArchive
    let filename: String
}

// MARK: - 恢复方式选择

private struct RestoreOptionsSheet: View {
    let pending: PendingRestore
    let currentBookCount: Int
    let onConfirm: (RestoreStrategy) -> Void
    let onCancel: () -> Void

    /// 覆盖的二次确认放在本页内部。alert 挂在 sheet 上才能正常弹出——
    /// 挂在父视图上会与正在展示的 sheet 抢同一个 presentation 通道。
    @State private var showReplaceConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "备份内容")) {
                    LabeledContent(String(localized: "文件"), value: pending.filename)
                    LabeledContent(
                        String(localized: "创建时间"),
                        value: pending.archive.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    LabeledContent(
                        String(localized: "书籍"),
                        value: String(localized: "\(pending.archive.books.count) 本")
                    )
                    LabeledContent(
                        String(localized: "章节"),
                        value: String(localized: "\(pending.archive.chapterCount) 章")
                    )
                    LabeledContent(
                        String(localized: "阅读记录"),
                        value: String(localized: "\(pending.archive.readingRecordCount) 条")
                    )
                    if !pending.archive.bookmarks.isEmpty {
                        LabeledContent(
                            String(localized: "书签与划线"),
                            value: String(localized: "\(pending.archive.bookmarks.count) 条")
                        )
                    }
                    if !pending.archive.bookSources.isEmpty {
                        LabeledContent(
                            String(localized: "书源"),
                            value: String(localized: "\(pending.archive.bookSources.count) 个")
                        )
                    }
                }

                Section {
                    Button { onConfirm(.merge) } label: {
                        optionRow(
                            title: RestoreStrategy.merge.displayName,
                            detail: RestoreStrategy.merge.detail,
                            systemImage: "arrow.triangle.merge",
                            tint: .accentColor
                        )
                    }
                    Button(role: .destructive) { showReplaceConfirm = true } label: {
                        optionRow(
                            title: RestoreStrategy.replace.displayName,
                            detail: RestoreStrategy.replace.detail,
                            systemImage: "exclamationmark.triangle",
                            tint: .red
                        )
                    }
                } header: {
                    Text(String(localized: "恢复方式"))
                } footer: {
                    Text(String(localized: "拿不准就选「合并」——它只会往书库里补东西，不会删掉任何现有内容。"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "从备份恢复"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消"), action: onCancel)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .alert(
                String(localized: "确认完全覆盖？"),
                isPresented: $showReplaceConfirm
            ) {
                Button(String(localized: "取消"), role: .cancel) {}
                Button(String(localized: "清空并恢复"), role: .destructive) {
                    onConfirm(.replace)
                }
            } message: {
                Text(String(
                    localized: "当前书库里的 \(currentBookCount) 本书、全部阅读进度、时长记录、书签与 AI 改写历史都会被删除，并替换成备份中的内容。此操作不可撤销，建议先对当前书库做一次备份。"
                ))
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func optionRow(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(minHeight: 44)
    }
}

#Preview {
    NavigationStack {
        BackupView()
    }
    .modelContainer(
        for: [
            Book.self,
            Chapter.self,
            ReadingRecord.self,
            ReadingSettings.self,
            ShelfPreferences.self,
            RewriteRecord.self,
            BookSource.self,
            Bookmark.self
        ],
        inMemory: true
    )
}
