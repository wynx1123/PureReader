import SwiftUI

struct ReaderSettingsPanel: View {
    @Bindable var viewModel: ReaderViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "字体")) {
                    HStack {
                        Text("A").font(.caption)
                        Slider(
                            value: Binding(
                                get: { viewModel.settings.fontSize },
                                set: { viewModel.setFontSize($0) }
                            ),
                            in: 14...28,
                            step: 1
                        )
                        Text("A").font(.title3)
                    }
                    .accessibilityLabel(String(localized: "字号"))

                    HStack {
                        Text(String(localized: "行距"))
                        Slider(
                            value: Binding(
                                get: { viewModel.settings.lineSpacing },
                                set: { viewModel.setLineSpacing($0) }
                            ),
                            in: 1.2...2.5,
                            step: 0.1
                        )
                        Text(String(format: "%.1f", viewModel.settings.lineSpacing))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }

                Section(String(localized: "边距")) {
                    Picker(String(localized: "页边距"), selection: Binding(
                        get: { viewModel.settings.pageMargin },
                        set: { viewModel.setMargin($0) }
                    )) {
                        ForEach(MarginMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(String(localized: "翻页")) {
                    Picker(String(localized: "翻页模式"), selection: Binding(
                        get: { viewModel.settings.pageTurnMode },
                        set: { viewModel.setPageTurnMode($0) }
                    )) {
                        ForEach(PageTurnMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section(String(localized: "背景")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                        ForEach(BackgroundType.allCases, id: \.self) { type in
                            Button {
                                viewModel.setBackground(type)
                            } label: {
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.readerBackground(type))
                                        .frame(height: 44)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(
                                                    viewModel.settings.backgroundColor == type
                                                    ? Color.accentColor : Color.secondary.opacity(0.25),
                                                    lineWidth: viewModel.settings.backgroundColor == type ? 2 : 1
                                                )
                                        }
                                    Text(type.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(String(localized: "听书")) {
                    HStack {
                        Text(String(localized: "语速"))
                        Slider(
                            value: Binding(
                                get: { viewModel.settings.ttsRate },
                                set: { viewModel.setTTSRate($0) }
                            ),
                            in: 0.5...2.0,
                            step: 0.1
                        )
                        Text(String(format: "%.1fx", viewModel.settings.ttsRate))
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }

                    Picker(String(localized: "音色"), selection: Binding(
                        get: { viewModel.settings.ttsVoice },
                        set: { viewModel.setTTSVoice($0) }
                    )) {
                        Text(String(localized: "系统默认")).tag("")
                        ForEach(TTSEngine.availableChineseVoices(), id: \.identifier) { voice in
                            Text(voice.name).tag(voice.identifier)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "阅读设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) {
                        viewModel.showSettings = false
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
