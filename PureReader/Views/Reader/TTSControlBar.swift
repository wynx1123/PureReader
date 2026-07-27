import SwiftUI

struct TTSControlBar: View {
    @Bindable var viewModel: ReaderViewModel
    @ObservedObject private var tts: TTSEngine
    let background: BackgroundType

    init(viewModel: ReaderViewModel, background: BackgroundType) {
        self.viewModel = viewModel
        self.background = background
        _tts = ObservedObject(wrappedValue: viewModel.tts)
    }

    var body: some View {
        HStack(spacing: 20) {
            Button {
                viewModel.previousPage()
            } label: {
                Image(systemName: "backward.fill")
                    .frame(width: 44, height: 44)
            }

            Button {
                viewModel.toggleTTS()
            } label: {
                Group {
                    if tts.isLoading {
                        ProgressView()
                            .tint(Color.readerForeground(background))
                    } else {
                        Image(systemName: playIcon)
                            .font(.title2)
                    }
                }
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
            .accessibilityLabel(viewModel.isTTSSpeaking && !viewModel.isTTSPaused
                                ? String(localized: "暂停")
                                : String(localized: "播放"))

            Button {
                viewModel.nextPage()
            } label: {
                Image(systemName: "forward.fill")
                    .frame(width: 44, height: 44)
            }

            Spacer(minLength: 8)

            Button {
                viewModel.stopTTS()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(String(localized: "停止听书"))
        }
        .foregroundStyle(Color.readerForeground(background))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var playIcon: String {
        if viewModel.isTTSSpeaking && !viewModel.isTTSPaused {
            return "pause.fill"
        }
        return "play.fill"
    }
}
