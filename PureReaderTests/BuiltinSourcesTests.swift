import XCTest
import Foundation
import SwiftData
@testable import PureReader

@MainActor
final class BuiltinSourcesTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([BookSource.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func bundledData() throws -> Data {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot
            .appendingPathComponent("PureReader/Resources/BuiltinSources.json")
        return try Data(contentsOf: url)
    }

    func testBundledSourcesAllImportAndStayEnabled() throws {
        let context = try makeContext()

        let result = try BookSourceImporter.importJSON(try bundledData(), into: context)

        XCTAssertEqual(result.changed, 3, "内置书源数量应为 3")
        XCTAssertEqual(result.disabled, 0, "精选内置书源不应有任何因兼容性被停用")
        XCTAssertEqual(result.enabled, 3)

        let imported = try context.fetch(FetchDescriptor<BookSource>())
        XCTAssertEqual(imported.count, 3)
        XCTAssertTrue(imported.allSatisfy(\.enabled), "内置书源导入后应全部启用")
        XCTAssertTrue(imported.allSatisfy { !$0.searchURL.isEmpty })
        XCTAssertTrue(imported.allSatisfy { !$0.groupName.isEmpty })
    }

    func testBundledSourcesHaveNoUnsupportedRuleSyntax() throws {
        let context = try makeContext()

        _ = try BookSourceImporter.importJSON(try bundledData(), into: context)
        let imported = try context.fetch(FetchDescriptor<BookSource>())

        let forbiddenTokens = ["@js:", "<js>", "@put:", "@get:", "@xpath:", "webview"]
        for source in imported {
            let value = source.ruleJSON.lowercased()
            for token in forbiddenTokens {
                XCTAssertFalse(
                    value.contains(token),
                    "「\(source.name)」规则不应包含不受支持语法 \(token)"
                )
            }
        }
    }

    func testReimportIsIdempotent() throws {
        let context = try makeContext()

        let data = try bundledData()
        _ = try BookSourceImporter.importJSON(data, into: context)
        _ = try BookSourceImporter.importJSON(data, into: context)

        let imported = try context.fetch(FetchDescriptor<BookSource>())
        XCTAssertEqual(imported.count, 3, "重复导入不应产生重复书源")
    }
}
