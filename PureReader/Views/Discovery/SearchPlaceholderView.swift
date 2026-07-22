import SwiftUI

/// Phase 4 实现完整搜索与书源
struct SearchPlaceholderView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(String(localized: "发现"))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "书源搜索将在后续版本开放"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(String(localized: "发现"))
        }
    }
}

#Preview {
    SearchPlaceholderView()
}
