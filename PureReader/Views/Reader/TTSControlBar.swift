import SwiftUI

struct TTSControlBar: View {
    @Bindable var viewModel: ReaderViewModel
    let background: BackgroundType

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
                Image(systemName: playIcon)
                    .font(.title2)
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
                Image(systemName: "xmark.circle.fill")
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
