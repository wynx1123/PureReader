import SwiftUI
import UIKit

struct ReaderSettingsPanel: View {
    @Bindable var viewModel: ReaderViewModel

    /// 关闭「跟随系统」时以当前系统亮度作为起点，滑块不会突然跳到某个默认值。
    @MainActor
    private var currentSystemBrightness: Double {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let value = Double(scene?.screen.brightness ?? 0.5)
        return min(1.0, max(0.1, value))
    }

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

                    // 缩进按「字符数」给选项，排版层再按当前字号换算，换字号不会跑偏
                    Picker(String(localized: "首行缩进"), selection: Binding(
                        get: { viewModel.settings.firstLineIndentChars },
                        set: { viewModel.setFirstLineIndent($0) }
                    )) {
                        Text(String(localized: "无")).tag(0.0)
                        Text(String(localized: "1 字")).tag(1.0)
                        Text(String(localized: "2 字")).tag(2.0)
                        Text(String(localized: "3 字")).tag(3.0)
                        Text(String(localized: "4 字")).tag(4.0)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text(String(localized: "段间距"))
                        Slider(
                            value: Binding(
                                get: { viewModel.settings.paragraphSpacingRatio },
                                set: { viewModel.setParagraphSpacing($0) }
                            ),
                            in: 0...1,
                            step: 0.05
                        )
                        Text(String(format: "%.2f", viewModel.settings.paragraphSpacingRatio))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Section(String(localized: "护眼与屏幕")) {
                    Toggle(isOn: Binding(
                        get: { viewModel.settings.keepScreenOn },
                        set: { viewModel.setKeepScreenOn($0) }
                    )) {
                        Label(String(localized: "屏幕常亮"), systemImage: "sun.max")
                    }

                    // brightnessOverride 用 <0 表示不接管系统亮度，
                    // UI 上拆成「跟随系统」开关 + 滑块，用户才不会被 -1 这种魔法值困惑
                    Toggle(isOn: Binding(
                        get: { viewModel.settings.brightnessOverride < 0 },
                        set: { follow in
                            viewModel.setBrightnessOverride(follow ? -1 : currentSystemBrightness)
                        }
                    )) {
                        Label(String(localized: "亮度跟随系统"), systemImage: "circle.lefthalf.filled")
                    }

                    if viewModel.settings.brightnessOverride >= 0 {
                        HStack {
                            Image(systemName: "sun.min").font(.caption)
                            Slider(
                                value: Binding(
                                    get: { min(1.0, max(0.1, viewModel.settings.brightnessOverride)) },
                                    set: { viewModel.setBrightnessOverride($0) }
                                ),
                                in: 0.1...1.0
                            )
                            Image(systemName: "sun.max").font(.title3)
                        }
                        .accessibilityLabel(String(localized: "阅读亮度"))
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

                    Picker(String(localized: "睡眠定时"), selection: Binding(
                        get: { viewModel.settings.sleepTimerMinutes },
                        set: { viewModel.setSleepTimer(minutes: $0) }
                    )) {
                        Text(String(localized: "关闭")).tag(0)
                        Text(String(localized: "15 分钟")).tag(15)
                        Text(String(localized: "30 分钟")).tag(30)
                        Text(String(localized: "60 分钟")).tag(60)
                    }

                    // 倒计时已经在跑时给出剩余时间，否则用户无法确认定时是否生效。
                    if viewModel.sleepRemainingSeconds > 0 {
                        LabeledContent(String(localized: "剩余")) {
                            Text(
                                Duration.seconds(viewModel.sleepRemainingSeconds)
                                    .formatted(.time(pattern: .minuteSecond))
                            )
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        }
                    }

                    // 与分钟定时互补：宁可多读几分钟也不在句子中间断掉
                    Toggle(isOn: Binding(
                        get: { viewModel.settings.sleepAfterChapter },
                        set: { viewModel.setSleepAfterChapter($0) }
                    )) {
                        Label(String(localized: "读完本章停止"), systemImage: "moon.zzz")
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
