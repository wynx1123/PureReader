import SwiftUI
import UIKit

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            BookshelfView()
                .tabItem {
                    Label(String(localized: "图书"), systemImage: "books.vertical.fill")
                }

            DiscoveryView()
                .tabItem {
                    Label(String(localized: "发现"), systemImage: "magnifyingglass")
                }

            StatsView()
                .tabItem {
                    Label(String(localized: "统计"), systemImage: "chart.bar.fill")
                }

            SettingsView()
                .tabItem {
                    Label(String(localized: "设置"), systemImage: "gearshape.fill")
                }
        }
        .tint(.accentColor)
        .onAppear {
            BookSourceImporter.seedBuiltInIfNeeded(context: modelContext)
            configureTabAppearance()
        }
    }

    private func configureTabAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

#Preview {
    MainTabView()
        .modelContainer(
            for: [
                Book.self,
                Chapter.self,
                ReadingRecord.self,
                ReadingSettings.self,
                ShelfPreferences.self,
                RewriteRecord.self,
                BookSource.self
            ],
            inMemory: true
        )
}
