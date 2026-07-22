import SwiftUI
import SwiftData

@main
struct PureReaderApp: App {
    private let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            Book.self,
            Chapter.self,
            ReadingRecord.self,
            ReadingSettings.self,
            ShelfPreferences.self,
            RewriteRecord.self,
            BookSource.self
        ])
        let config = ModelConfiguration(
            "PureReader",
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // 迁移失败时使用内存库，避免启动崩溃
            let fallback = ModelConfiguration(
                "PureReader-Fallback",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("SwiftData 初始化失败: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
        .modelContainer(modelContainer)
    }
}
