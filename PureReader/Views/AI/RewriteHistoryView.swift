import SwiftUI
import SwiftData

/// 改写历史：单条撤销 / 收藏 / 一键还原
struct RewriteHistoryView: View {
    @Bindable var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var records: [RewriteRecord] = []
    @State private var errorMessage: String?
    @State private var confirmRestoreAll = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView(
                        String(localized: "暂无改写记录"),
                        systemImage: "clock.arrow.circlepath",
                        description: Text(String(localized: "在阅读页使用 AI 改写后会出现在这里"))
                    )
                } else {
                    List {
                        ForEach(records, id: \.persistentModelID) { record in
                            recordRow(record)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(String(localized: "改写历史"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "全部还原"), role: .destructive) {
                        confirmRestoreAll = true
                    }
                    .disabled(records.allSatisfy(\.isUndone))
                }
            }
            .onAppear { reload() }
            .alert(String(localized: "一键还原"), isPresented: $confirmRestoreAll) {
                Button(String(localized: "取消"), role: .cancel) {}
                Button(String(localized: "还原全部"), role: .destructive) {
                    do {
                        let n = try viewModel.undoAllRewrites()
                        statusMessage = String(localized: "已还原 \(n) 处改写")
                        reload()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } message: {
                Text(String(localized: "将按时间逆序把本书所有未撤销的 AI 改写还原为原文。"))
            }
            .alert(String(localized: "提示"), isPresented: Binding(
                get: { errorMessage != nil || statusMessage != nil },
                set: { if !$0 { errorMessage = nil; statusMessage = nil } }
            )) {
                Button(String(localized: "好"), role: .cancel) {
                    errorMessage = nil
                    statusMessage = nil
                }
            } message: {
                Text(errorMessage ?? statusMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func recordRow(_ record: RewriteRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.timestamp, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if record.isUndone {
                    Text(String(localized: "已撤销"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                } else if record.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }

            if !record.branchLabel.isEmpty {
                Text(String(localized: "分支：\(record.branchLabel)"))
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }

            if !record.userRequest.isEmpty {
                Text(String(localized: "要求：\(record.userRequest)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(String(localized: "原文"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(record.originalText)
                .font(.footnote)
                .lineLimit(4)
                .foregroundStyle(.secondary)

            Text(String(localized: "改写"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(record.rewrittenText)
                .font(.footnote)
                .lineLimit(4)

            HStack(spacing: 16) {
                Button {
                    viewModel.toggleFavorite(record)
                    reload()
                } label: {
                    Label(
                        record.isFavorite
                            ? String(localized: "取消收藏")
                            : String(localized: "收藏"),
                        systemImage: record.isFavorite ? "star.slash" : "star"
                    )
                }
                .buttonStyle(.borderless)

                if !record.isUndone {
                    Button(role: .destructive) {
                        do {
                            _ = try viewModel.undoRewrite(record)
                            reload()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    } label: {
                        Label(String(localized: "撤销"), systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        records = viewModel.fetchRewriteRecords()
    }
}
