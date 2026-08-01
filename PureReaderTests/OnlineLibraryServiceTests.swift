import XCTest
import Foundation
@testable import PureReader

final class OnlineLibraryServiceTests: XCTestCase {
    func testStableURLDedupAndAddedCount() {
        let fetched = [
            SourceChapterItem(title: "旧章", url: "HTTPS://Example.com:443/1#top", index: 0),
            SourceChapterItem(title: "旧章重复", url: "https://example.com/1", index: 1),
            SourceChapterItem(title: "新章", url: "https://example.com/2", index: 2)
        ]
        let result = OnlineLibraryService.mergeCatalog(
            existingURLs: ["https://example.com/1"], fetched: fetched
        )
        XCTAssertEqual(result.chapters.count, 2)
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.newChapters.first?.title, "新章")
    }

    func testUnreadResumeOnlyReturnsValidNextChapter() {
        XCTAssertEqual(OnlineLibraryService.firstUnreadIndex(totalChapters: 10, highestReadIndex: 3, currentIndex: 0), 4)
        XCTAssertEqual(OnlineLibraryService.firstUnreadIndex(totalChapters: 10, highestReadIndex: -1, currentIndex: 2), 2)
        XCTAssertNil(OnlineLibraryService.firstUnreadIndex(totalChapters: 10, highestReadIndex: 9, currentIndex: 9))
    }

    func testCacheManifestPathIsStableAndScoped() {
        let book = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let chapter = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        XCTAssertEqual(
            OnlineLibraryService.cacheRelativePath(bookID: book, chapterID: chapter),
            "OfflineChapters/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB.txt"
        )
    }

    func testOriginIncludesSchemeAndEffectivePort() {
        XCTAssertTrue(BookSourceEngine.isSameOrigin(
            URL(string: "https://example.com/a"),
            URL(string: "https://EXAMPLE.com:443/b")
        ))
        XCTAssertFalse(BookSourceEngine.isSameOrigin(
            URL(string: "https://example.com/a"),
            URL(string: "http://example.com/a")
        ))
        XCTAssertFalse(BookSourceEngine.isSameOrigin(
            URL(string: "https://example.com:443/a"),
            URL(string: "https://example.com:8443/a")
        ))
    }

    func testCrossOriginHeadersDropCredentialsButKeepPublicHeaders() {
        let json = #"{"Cookie":"sid=secret","Authorization":"Bearer secret","X-API-Key":"secret","User-Agent":"Reader","Accept-Language":"zh-CN"}"#
        let headers = BookSourceEngine.scopedHeaders(
            json,
            target: URL(string: "https://cdn.example.net/chapter")!,
            trustedSource: URL(string: "https://books.example.com:443/source")!
        )
        XCTAssertNil(headers["Cookie"])
        XCTAssertNil(headers["Authorization"])
        XCTAssertNil(headers["X-API-Key"])
        XCTAssertEqual(headers["User-Agent"], "Reader")
        XCTAssertEqual(headers["Accept-Language"], "zh-CN")
    }

    func testSameOriginHeadersKeepExplicitCredentials() {
        let json = #"{"Cookie":"sid=secret","Authorization":"Bearer secret"}"#
        let headers = BookSourceEngine.scopedHeaders(
            json,
            target: URL(string: "https://books.example.com/chapter")!,
            trustedSource: URL(string: "https://books.example.com:443/source")!
        )
        XCTAssertEqual(headers["Cookie"], "sid=secret")
        XCTAssertEqual(headers["Authorization"], "Bearer secret")
    }

    func testHTTPNeverReceivesExplicitCredentials() {
        let json = #"{"Cookie":"sid=secret","User-Agent":"Reader"}"#
        let headers = BookSourceEngine.scopedHeaders(
            json,
            target: URL(string: "http://books.example.com/chapter")!,
            trustedSource: URL(string: "http://books.example.com/source")!
        )
        XCTAssertNil(headers["Cookie"])
        XCTAssertEqual(headers["User-Agent"], "Reader")
    }

    func testSensitiveRequestCannotUseCleartextFallback() {
        XCTAssertFalse(BookSourceEngine.allowsCleartextFallback(headers: ["Authorization": "Bearer secret"]))
        XCTAssertFalse(BookSourceEngine.allowsCleartextFallback(headers: ["Cookie": "sid=secret"]))
        XCTAssertTrue(BookSourceEngine.allowsCleartextFallback(headers: ["User-Agent": "Reader"]))
    }

    func testRedirectSanitizesHTTPSDowngradeAndPortChange() {
        var downgrade = URLRequest(url: URL(string: "http://example.com/chapter")!)
        downgrade.setValue("sid=secret", forHTTPHeaderField: "Cookie")
        downgrade.setValue("Reader", forHTTPHeaderField: "User-Agent")
        let sanitizedDowngrade = BookSourceEngine.sanitizedRedirectRequest(
            downgrade,
            from: URL(string: "https://example.com/chapter")
        )
        XCTAssertNil(sanitizedDowngrade.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(sanitizedDowngrade.value(forHTTPHeaderField: "User-Agent"), "Reader")

        var portChange = URLRequest(url: URL(string: "https://example.com:8443/chapter")!)
        portChange.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        XCTAssertNil(BookSourceEngine.sanitizedRedirectRequest(
            portChange,
            from: URL(string: "https://example.com/chapter")
        ).value(forHTTPHeaderField: "Authorization"))
    }

    func testCatalogAlignmentInsertsAndReordersWhileRetainingDeletedLocalChapter() {
        let fetched = [
            SourceChapterItem(title: "一（新标题）", url: "https://example.com/1", index: 0),
            SourceChapterItem(title: "插入章", url: "https://example.com/1.5", index: 1),
            SourceChapterItem(title: "二", url: "https://example.com/2", index: 2)
        ]
        let aligned = OnlineLibraryService.alignCatalog(
            existingURLs: [
                "https://example.com/2",
                "https://example.com/deleted",
                "https://example.com/1"
            ],
            fetched: fetched
        )
        XCTAssertEqual(aligned.items.map(\.url), [
            "https://example.com/1",
            "https://example.com/1.5",
            "https://example.com/2",
            "https://example.com/deleted"
        ])
        XCTAssertEqual(aligned.addedCount, 1)
        XCTAssertEqual(aligned.items.first?.title, "一（新标题）")
        XCTAssertTrue(aligned.items.last?.isRetainedRemoteDeletion == true)
    }

    func testCacheGenerationRejectsStaleAsyncWork() {
        XCTAssertTrue(OnlineLibraryService.generationIsCurrent(captured: 7, current: 7))
        XCTAssertFalse(OnlineLibraryService.generationIsCurrent(captured: 7, current: 8))
    }
}
