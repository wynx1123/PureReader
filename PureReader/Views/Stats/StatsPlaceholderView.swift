import SwiftUI

/// Phase 3 实现阅读统计
struct StatsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(String(localized: "阅读统计"))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "开始阅读后，这里会显示你的阅读时长与热力图"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(String(localized: "统计"))
        }
    }
}

#Preview {
    StatsPlaceholderView()
}
