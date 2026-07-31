import SwiftUI
import SwiftData

// MARK: - Book Source Health Check View

/// 书源完整健康检测页面。
/// 分四步执行：搜索 → 详情 → 目录 → 正文，每步显示实时状态。
struct BookSourceHealthView: View {
    let source: BookSource
    @Environment(\.dismiss) private var dismiss

    @State private var isRunning = false
    @State private var report: BookSourceHealthReport?
    @State private var steps: [CheckStep: (CheckStatus, String?)] = [:]
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                // 标题
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.name)
                            .font(.headline)
                        if !source.groupName.isEmpty {
                            Text(source.groupName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 检测步骤
                Section(String(localized: "检测步骤")) {
                    ForEach(CheckStep.allCases, id: \.rawValue) { step in
                        stepRow(step)
                    }
                }

                // 结果
                if let report, !isRunning {
                    Section(String(localized: "检测结果")) {
                        LabeledContent(String(localized: "总耗时")) {
                            Text(String(localized: "\(report.totalDurationMilliseconds) ms"))
                        }
                        LabeledContent(String(localized: "建议操作")) {
                            Text(report.recommendedAction.displayName)
                                .foregroundStyle(actionColor(report.recommendedAction))
                        }
                    }

                    if report.isFullyHealthy {
                        Section {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(String(localized: "该书源四步检测全部通过，可以正常使用。"))
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "完整检测"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "开始检测")) {
                        startCheck()
                    }
                    .disabled(isRunning)
                }
            }
            .overlay {
                if isRunning {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(String(localized: "正在检测…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(
                String(localized: "检测失败"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(String(localized: "好"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Step row

    @ViewBuilder
    private func stepRow(_ step: CheckStep) -> some View {
        let stepState = steps[step] ?? (.notRun, nil)
        HStack {
            Image(systemName: stepIcon(for: stepState.0))
                .foregroundStyle(stepColor(for: stepState.0))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.displayName)
                    .font(.subheadline)
                if let message = stepState.1 {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(stepState.0.displayName)
                .font(.caption)
                .foregroundStyle(stepColor(for: stepState.0))
        }
    }

    private func stepIcon(for status: CheckStatus) -> String {
        switch status {
        case .notRun: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .verificationRequired: return "exclamationmark.triangle.fill"
        case .rateLimited: return "clock.fill"
        case .unsupported: return "slash.circle.fill"
        }
    }

    private func stepColor(for status: CheckStatus) -> Color {
        switch status {
        case .notRun: return .secondary
        case .running: return .blue
        case .passed: return .green
        case .failed: return .red
        case .verificationRequired: return .orange
        case .rateLimited: return .yellow
        case .unsupported: return .gray
        }
    }

    private func actionColor(_ action: HealthAction) -> Color {
        switch action {
        case .none: return .green
        case .enable: return .blue
        case .disable: return .red
        case .verify: return .orange
        case .retry: return .yellow
        case .updateRules: return .purple
        }
    }

    // MARK: - Start check

    private func startCheck() {
        isRunning = true
        report = nil
        steps = [:]
        errorMessage = nil

        for step in CheckStep.allCases {
            steps[step] = (.notRun, nil)
        }

        Task {
            let report = await BookSourceEngine.validateFullHealth(source) { step, status, message in
                steps[step] = (status, message)
            }
            isRunning = false
            self.report = report
        }
    }
}