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
                    .pickerStyle(.segmented)
                }

                Section(String(localized: "页面信息")) {
                    Toggle(isOn: Binding(
                        get: { viewModel.settings.showHeader },
                        set: { viewModel.setShowHeader($0) }
                    )) {
                        Label(String(localized: "显示书名与章节"), systemImage: "text.alignleft")
                    }

                    Toggle(isOn: Binding(
                        get: { viewModel.settings.showPageNumber },
                        set: { viewModel.setShowPageNumber($0) }
                    )) {
                        Label(String(localized: "显示页码"), systemImage: "number")
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
                    Picker(String(localized: "语音引擎"), selection: Binding(
                        get: { viewModel.settings.ttsProvider },
                        set: { viewModel.setTTSProvider($0) }
                    )) {
                        ForEach(TTSProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

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

                    if viewModel.settings.ttsProvider != .system {
                        LabeledContent(String(localized: "模型")) {
                            let model = NetworkTTSConfig.model(for: viewModel.settings.ttsProvider)
                            Text(model.isEmpty ? String(localized: "未选择") : model)
                                .lineLimit(1)
                                .foregroundStyle(model.isEmpty ? Color.secondary : Color.primary)
                        }
                    }

                    if viewModel.settings.ttsProvider == .fishAudio {
                        TextField(String(localized: "音色模型 ID（可选）"), text: Binding(
                            get: { viewModel.settings.ttsVoice },
                            set: { viewModel.setTTSVoice($0) }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    } else {
                        Picker(String(localized: "音色"), selection: Binding(
                            get: { viewModel.settings.ttsVoice },
                            set: { viewModel.setTTSVoice($0) }
                        )) {
                            if viewModel.settings.ttsProvider == .system {
                                Text(String(localized: "系统默认")).tag("")
                            }
                            ForEach(viewModel.availableTTSVoices) { voice in
                                Text(voice.name).tag(voice.id)
                            }
                        }
                    }

                    if viewModel.settings.ttsProvider == .openAICompatible {
                        TextField(String(localized: "自定义音色 ID"), text: Binding(
                            get: { viewModel.settings.ttsVoice },
                            set: { viewModel.setTTSVoice($0) }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }

                    if viewModel.settings.ttsProvider != .system {
                        Label(String(localized: "AI 合成语音"), systemImage: "waveform.badge.sparkles")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
