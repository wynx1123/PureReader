import SwiftUI
import SwiftData

// MARK: - Selection + loading + result host

@MainActor
struct AIRewriteSheet: View {
    let pageText: String
    let pageUTF16Offset: Int
    let chapterContent: String
    let chapterTitle: String
    let chapterIndex: Int
    let chapterID: UUID
    let book: Book
    let onConfirm: (RewriteApplication) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phase: RewritePhase = .selecting
    @State private var selectedText: String = ""
    @State private var userRequest: String = ""
    @State private var rewrittenText: String = ""
    @State private var warnings: [String] = []
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var refineNote: String = ""
    @State private var showRefine = false
    @State private var style: RewriteStylePreset = AIConfig.stylePreset
    @State private var rewritePlan: RewritePlan?
    @State private var progressStage: RewriteProgressStage = .planning
    @State private var resolvedTargetOffset: Int?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .selecting:
                    selectingView
                case .loading:
                    loadingView
                case .result:
                    resultView
                }
            }
            .navigationTitle(String(localized: "AI 情节改写"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
            }
            .alert(String(localized: "改写失败"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(String(localized: "好"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if selectedText.isEmpty {
                    selectedText = pageText
                }
                style = AIConfig.stylePreset
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Selecting

    private var selectingView: some View {
        Form {
            if !AIConfig.isConfigured {
                Section {
                    Label(
                        String(localized: "请先在「设置 → AI」中配置 API Key"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section {
                Text(String(localized: "📋 选择要改写的原文范围"))
                    .font(.headline)
                TextEditor(text: $selectedText)
                    .font(.body)
                    .frame(minHeight: 160)
                    .accessibilityLabel(String(localized: "改写原文"))
                Button(String(localized: "使用整页文本")) {
                    selectedText = pageText
                }
                .font(.caption)
                Text(String(localized: "可删除前后文字来缩小范围；请保留原文字词，以便准确替换。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "改写风格")) {
                Picker(String(localized: "风格"), selection: $style) {
                    ForEach(RewriteStylePreset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(String(localized: "📝 你希望这段情节怎么改？")) {
                TextField(
                    String(localized: "例如：让主角选择放过反派…"),
                    text: $userRequest,
                    axis: .vertical
                )
                .lineLimit(3...8)
            }

            Section {
                Button {
                    // 整页分段：取前若干自然段作为批量改写入口
                    selectedText = pageText
                    Task { await runRewrite() }
                } label: {
                    HStack {
                        Spacer()
                        Text(String(localized: "批量：改写整页"))
                        Spacer()
                    }
                }
                .disabled(
                    pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !AIConfig.isConfigured
                        || isWorking
                )

                Button {
                    Task { await runRewrite() }
                } label: {
                    HStack {
                        Spacer()
                        if isWorking {
                            ProgressView()
                        } else {
                            Text(String(localized: "✨ 开始改写"))
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(
                    selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !AIConfig.isConfigured
                        || isWorking
                )
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text(progressStage.title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(String(localized: "情节规划 → 正文生成 → 一致性检查"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }

                if let rewritePlan {
                    planBlock(rewritePlan)
                }

                Text(String(localized: "左右对比"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                // iPhone 上用上下对比更清晰；宽屏仍可读
                VStack(spacing: 12) {
                    groupBlock(
                        title: String(localized: "原文"),
                        text: selectedText,
                        tint: Color.secondary.opacity(0.12)
                    )
                    Image(systemName: "arrow.down")
                        .foregroundStyle(.tertiary)
                    groupBlock(
                        title: String(localized: "改写结果"),
                        text: rewrittenText,
                        tint: Color.accentColor.opacity(0.10)
                    )
                }

                HStack(spacing: 12) {
                    Button(String(localized: "重新改写")) {
                        Task { await runRewrite(retry: true) }
                    }
                    .buttonStyle(.bordered)

                    Button(String(localized: "微调")) {
                        showRefine = true
                    }
                    .buttonStyle(.bordered)

                    Button(String(localized: "确认替换")) {
                        Task { await confirmReplace() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isWorking
                            || rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                .padding(.top, 8)
            }
            .padding()
        }
        .alert(String(localized: "微调要求"), isPresented: $showRefine) {
            TextField(String(localized: "补充要求"), text: $refineNote)
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "提交")) {
                Task { await runRefine() }
            }
        } message: {
            Text(String(localized: "在现有改写基础上追加要求"))
        }
    }

    private func groupBlock(title: String, text: String, tint: Color = Color(.secondarySystemBackground)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .textSelection(.enabled)
        }
    }

    private func planBlock(_ plan: RewritePlan) -> some View {
        let preserveSummary = plan.mustPreserve.prefix(3).joined(separator: "；")
        return VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "情节结构方案"), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.subheadline.weight(.semibold))
            Text(plan.intentSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(Array(plan.storyBeats.prefix(5).enumerated()), id: \.offset) { index, beat in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tint)
                        .frame(width: 18, height: 18)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                    Text(beat)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !plan.mustPreserve.isEmpty {
                Text(String(localized: "保留：\(preserveSummary)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private func runRewrite(retry: Bool = false) async {
        isWorking = true
        phase = .loading
        progressStage = .planning
        errorMessage = nil
        defer { isWorking = false }

        do {
            let context = await buildContext(query: userRequest)
            resolvedTargetOffset = context.targetUTF16Offset ?? pageUTF16Offset
            let temp = retry ? min(1.0, AIConfig.temperature + 0.1) : AIConfig.temperature
            let outcome = try await AIRewriteEngine.rewriteStructured(
                context: context,
                userRequest: userRequest,
                style: style,
                temperature: temp,
                progress: { stage in
                    progressStage = stage
                }
            )
            rewrittenText = outcome.text
            rewritePlan = outcome.plan
            warnings = outcome.validation.warnings
            phase = .result
        } catch {
            errorMessage = error.localizedDescription
            phase = .selecting
        }
    }

    private func runRefine() async {
        guard !refineNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isWorking = true
        phase = .loading
        progressStage = .planning
        defer { isWorking = false }
        do {
            let combinedQuery = [userRequest, refineNote]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            let context = await buildContext(query: combinedQuery)
            resolvedTargetOffset = context.targetUTF16Offset ?? pageUTF16Offset
            let outcome = try await AIRewriteEngine.refineStructured(
                context: context,
                originalRequest: userRequest,
                refineNote: refineNote,
                previousRewrite: rewrittenText,
                style: style,
                progress: { stage in
                    progressStage = stage
                }
            )
            rewrittenText = outcome.text
            rewritePlan = outcome.plan
            warnings = outcome.validation.warnings
            userRequest = combinedQuery
            phase = .result
            refineNote = ""
        } catch {
            errorMessage = error.localizedDescription
            phase = .result
        }
    }

    private func confirmReplace() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await onConfirm(
                RewriteApplication(
                    originalText: selectedText,
                    rewrittenText: rewrittenText,
                    userRequest: userRequest,
                    style: style,
                    expectedUTF16Offset: resolvedTargetOffset ?? pageUTF16Offset
                )
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildContext(query: String) async -> RewriteContext {
        let bookID = book.id
        let index = BookUnderstandingCoordinator.shared.vectorIndex(for: bookID)
        let anchors = BookUnderstandingCoordinator.shared.memoryAnchors(for: bookID)
        let names = ContextAssembler.extractCharacterNames(from: selectedText)
        let anchorText = anchors?.promptBlock(currentChapter: chapterIndex, queryNames: names) ?? ""

        return await ContextAssembler.assembleHybrid(
            chapterContent: chapterContent,
            chapterTitle: chapterTitle,
            chapterIndex: chapterIndex,
            originalText: selectedText,
            userRequest: query,
            bookTitle: book.title,
            author: book.author,
            expectedUTF16Offset: pageUTF16Offset,
            vectorIndex: index,
            memoryAnchorText: anchorText
        )
    }
}
