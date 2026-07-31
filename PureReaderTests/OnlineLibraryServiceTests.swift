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

    @MainActor
    func testExportOnlyCachedModeUsesDiskCacheInsteadOfTransientMemory() throws {
        let bookID = UUID()
        let chapterID = UUID()
        let path = try OnlineLibraryService.writeCachedText(
            "cached body",
            bookID: bookID,
            chapterID: chapterID
        )
        defer { try? OnlineLibraryService.purgeCache(bookID: bookID) }

        let book = Book(id: bookID, title: "Cached export")
        let chapter = Chapter(id: chapterID, index: 0, title: "One", content: "memory body")
        chapter.offlineCachePath = path

        let url = try BookExportService.export(
            book: book,
            chapters: [chapter],
            format: .txt,
            options: .cachedOnly
        )
        let exported = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(exported.contains("cached body"))
        XCTAssertFalse(exported.contains("memory body"))
    }

    func testEPUBXMLContentIsEscaped() {
        XCTAssertEqual(
            BookExportService.escapedXMLForTesting("A&B <tag> \"quote\" 'single'"),
            "A&amp;B &lt;tag&gt; &quot;quote&quot; &apos;single&apos;"
        )
    }

    func testBuiltInAliceRulesMatchCurrentMarkup() {
        let searchHTML = """
        <div class="list-group-item">
          <h5><a href="/novel/42573.html">就业推荐法案</a></h5>
          <p class="mb-1 text-muted">作者：<a href="/search?q=author">作者名</a></p>
          <p class="content-txt">简介内容</p>
        </div>
        """
        let searchBlocks = RuleParser.getStrings(from: searchHTML, rule: "div.list-group-item")
        XCTAssertEqual(searchBlocks.count, 1)
        XCTAssertEqual(RuleParser.getString(from: searchBlocks[0], rule: "h5 a@text"), "就业推荐法案")
        XCTAssertEqual(RuleParser.getString(from: searchBlocks[0], rule: "h5 a@href", baseURL: URL(string: "https://www.alicesw.com")), "https://www.alicesw.com/novel/42573.html")

        let tocHTML = "<ul class=\"section-list fix\"><li><a href=\"/book/44049/1.html\">全1章</a></li></ul>"
        let tocBlocks = RuleParser.getStrings(from: tocHTML, rule: "ul.section-list li")
        XCTAssertEqual(tocBlocks.count, 1)
        XCTAssertEqual(RuleParser.getString(from: tocBlocks[0], rule: "a@text"), "全1章")

        let contentHTML = "<div class=\"content_txt\"><p>第一段</p><p>第二段</p></div>"
        XCTAssertEqual(
            RuleParser.getString(from: contentHTML, rule: "div.content_txt@text"),
            "第一段\n第二段"
        )
    }

    func testBuiltInQBTRRulesDoNotTruncateLargeCatalog() {
        let chapters = (1...402).map { index in
            "<li><a href=\"/tongren/9872/\(index).html\">第\(index)节</a></li>"
        }.joined()
        let html = "<div class=\"book_list\"><ul>\(chapters)</ul></div>"
        let blocks = RuleParser.getStrings(
            from: html,
            rule: "div.book_list ul li",
            limit: 5_000
        )
        XCTAssertEqual(blocks.count, 402)
        XCTAssertEqual(RuleParser.getString(from: blocks.last ?? "", rule: "a@text"), "第402节")
        XCTAssertEqual(
            RuleParser.getString(
                from: blocks.last ?? "",
                rule: "a@href",
                baseURL: URL(string: "https://www.qbtr.org/tongren/9872.html")
            ),
            "https://www.qbtr.org/tongren/9872/402.html"
        )
    }


    func testBuiltInAliceCatalogUsesDedicatedFullCatalogMarkup() {
        let chapters = (1...12).map { index in
            #"<li><a href="/book/8487/hash\#(index).html">第\#(index)章</a></li>"#
        }.joined()
        let html = #"<ul class="mulu_list">\#(chapters)</ul>"#
        let items = BookSourceEngine.parseChaptersForTesting(
            body: html,
            base: URL(string: "https://www.alicesw.com/other/chapters/id/8289.html")!,
            rules: ParseRule(
                chapterList: "ul.mulu_list li",
                chapterName: "a@text",
                chapterUrl: "a@href"
            )
        )
        XCTAssertEqual(items.count, 12)
        XCTAssertEqual(items.first?.title, "第1章")
        XCTAssertEqual(items.first?.url, "https://www.alicesw.com/book/8487/hash1.html")
        XCTAssertEqual(items.last?.index, 11)
    }

    func testBuiltInQBTRCatalogSortsNumericallyAndDoesNotStartAtRecentChapter() {
        let numbers = Array(1...475).reversed()
        let links = numbers.map { number in
            #"<li><a href="/tongren/9948/\#(number).html">第\#(number)章</a></li>"#
        }.joined()
        let html = #"<div class="book_list"><ul>\#(links)</ul></div>"#
        let items = BookSourceEngine.parseChaptersForTesting(
            body: html,
            base: URL(string: "https://www.qbtr.org/tongren/9948.html")!,
            rules: ParseRule(
                chapterList: "div.book_list ul li",
                chapterName: "a@text",
                chapterUrl: "a@href"
            )
        )
        XCTAssertEqual(items.count, 475)
        XCTAssertEqual(URL(string: items.first?.url ?? "")?.lastPathComponent, "1.html")
        XCTAssertEqual(URL(string: items.last?.url ?? "")?.lastPathComponent, "475.html")
        XCTAssertEqual(items.map(\.index), Array(0..<475))
    }

    func testCoverFallbackPrefersBookCoverAndLazyLoadedURL() {
        let html = """
        <img src="/template/icon.svg">
        <img class="lazyload_book_cover fengmian2" src="/placeholder.webp" data-src="https://img.example.com/actual.webp">
        """
        XCTAssertEqual(
            BookSourceEngine.extractCoverURLForTesting(
                body: html,
                base: URL(string: "https://www.alicesw.com/novel/8289.html")!
            ),
            "https://img.example.com/actual.webp"
        )
    }

    func testCacheGenerationRejectsStaleAsyncWork() {
        XCTAssertTrue(OnlineLibraryService.generationIsCurrent(captured: 7, current: 7))
        XCTAssertFalse(OnlineLibraryService.generationIsCurrent(captured: 7, current: 8))
    }
}
