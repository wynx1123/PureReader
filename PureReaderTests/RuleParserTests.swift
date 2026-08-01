import XCTest
@testable import PureReader

/// 规则解析器测试：JSON 模板列表 / 块级目录 / 单篇 JSON 正文
final class RuleParserTests: XCTestCase {

    private let linpxSearch = """
    {"novels": [
      {"id": "1001", "title": "甲", "userName": "作者A", "desc": "简介A", "coverUrl": "https://img/1.jpg"},
      {"id": "1002", "title": "乙", "userName": "作者B", "desc": "简介B", "coverUrl": "https://img/2.jpg"}
    ], "total": 2}
    """

    // MARK: - JSON 模板列表

    func testTemplateListRendersPerItemURL() throws {
        let rule = "https://api.example.com/novel/{{$.novels.id}}/cache"
        let urls = RuleParser.getStrings(from: linpxSearch, rule: rule, baseURL: nil)
        XCTAssertEqual(urls, [
            "https://api.example.com/novel/1001/cache",
            "https://api.example.com/novel/1002/cache",
        ])
    }

    func testTemplateListMultiPathAlignment() throws {
        let rule = "https://api.example.com/{{$.novels.id}}/{{$.novels.title}}"
        let urls = RuleParser.getStrings(from: linpxSearch, rule: rule, baseURL: nil)
        XCTAssertEqual(urls, [
            "https://api.example.com/1001/甲",
            "https://api.example.com/1002/乙",
        ])
    }

    func testTemplateListMissingPathReturnsEmpty() throws {
        let rule = "https://api.example.com/{{$.novels.seriesId}}/cache"
        let urls = RuleParser.getStrings(from: linpxSearch, rule: rule, baseURL: nil)
        XCTAssertTrue(urls.isEmpty)
    }

    // MARK: - 块级解析（bookList 分块 + 块内模板）

    @MainActor
    func testBlockSearchParsing() throws {
        let source = BookSource(
            name: "测试源",
            groupName: "测试",
            searchURL: "https://api.example.com/search",
            bookURL: "https://api.example.com",
            tocURL: "",
            contentURL: "",
            rules: ParseRule(
                bookList: "$.novels",
                name: "$.title",
                author: "$.userName",
                intro: "$.desc",
                coverUrl: "$.coverUrl",
                bookUrl: "https://api.example.com/novel/{{$.id}}/cache",
                tocUrl: nil,
                chapterList: nil,
                chapterName: nil,
                chapterUrl: nil,
                content: nil,
                nextPage: nil,
                replaceRegex: nil
            ),
            enabled: true,
            format: .pureReader,
            comment: "",
            weight: 1
        )
        let snapshot = BookSourceSnapshot(source)
        let items = BookSourceEngine.parseSearchFromRoot(
            body: linpxSearch, url: URL(string: "https://api.example.com/search")!, source: snapshot
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].name, "甲")
        XCTAssertEqual(items[0].bookURL, "https://api.example.com/novel/1001/cache")
        XCTAssertEqual(items[1].name, "乙")
    }

    // MARK: - 单篇 JSON 目录（zip fallback）

    func testSingleShotJSONTOC() throws {
        let single = """
        {"id": "1001", "title": "单篇标题", "content": "正文……", "series": null}
        """
        let rules = ParseRule(
            bookList: nil, name: nil, author: nil, intro: nil, coverUrl: nil, bookUrl: nil,
            tocUrl: nil,
            chapterList: "$.novels",
            chapterName: "$.title",
            chapterUrl: "https://api.example.com/novel/{{$.id}}/cache",
            content: "$.content",
            nextPage: nil, replaceRegex: nil
        )
        let chapters = BookSourceEngine.parseChapters(
            body: single, base: URL(string: "https://api.example.com")!, rules: rules
        )
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters.first?.name, "单篇标题")
        XCTAssertEqual(chapters.first?.url, "https://api.example.com/novel/1001/cache")
    }

    // MARK: - 文本提取

    func testTextNodesOnlyDirectText() throws {
        let html = "<div>开头<b>子元素</b>结尾</div>"
        let text = RuleParser.getString(from: html, rule: "div@textnodes", baseURL: nil)
        XCTAssertEqual(text, "开头结尾")
    }

    func testNumericEntitiesDecoded() throws {
        let html = "<p>&#20320;&#22909; &amp; &#x4E16;&#x754C;</p>"
        let text = RuleParser.getString(from: html, rule: "p@text", baseURL: nil)
        XCTAssertEqual(text, "你好 & 世界")
    }
}

    func testTemplateListMultiPathAlignment() throws {
        let rule = "https://api.example.com/{{$.novels.id}}/{{$.novels.title}}"
        let urls = RuleParser.getStrings(from: linpxSearch, rule: rule, baseURL: nil)
        XCTAssertEqual(urls, [
            "https://api.example.com/1001/甲",
            "https://api.example.com/1002/乙",
        ])
    }

    func testTemplateListMissingPathReturnsEmpty() throws {
        let rule = "https://api.example.com/{{$.novels.seriesId}}/cache"
        let urls = RuleParser.getStrings(from: linpxSearch, rule: rule, baseURL: nil)
        XCTAssertTrue(urls.isEmpty)
    }

    // MARK: - 块级解析（bookList 分块 + 块内模板）

    @MainActor
    func testBlockSearchParsing() throws {
        let source = BookSource(
            name: "测试源",
            groupName: "测试",
            searchURL: "https://api.example.com/search",
            bookURL: "https://api.example.com",
            tocURL: "",
            contentURL: "",
            rules: ParseRule(
                bookList: "$.novels",
                name: "$.title",
                author: "$.userName",
                intro: "$.desc",
                coverUrl: "$.coverUrl",
                bookUrl: "https://api.example.com/novel/{{$.id}}/cache",
                tocUrl: nil,
                chapterList: nil,
                chapterName: nil,
                chapterUrl: nil,
                content: nil,
                nextPage: nil,
                replaceRegex: nil
            ),
            enabled: true,
            format: .pureReader,
            comment: "",
            weight: 1
        )
        let snapshot = BookSourceSnapshot(source)
        let items = BookSourceEngine.parseSearchFromRoot(
            body: linpxSearch, url: URL(string: "https://api.example.com/search")!, source: snapshot
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].name, "甲")
        XCTAssertEqual(items[0].bookURL, "https://api.example.com/novel/1001/cache")
        XCTAssertEqual(items[1].name, "乙")
    }

    // MARK: - 单篇 JSON 目录（zip fallback）

    func testSingleShotJSONTOC() throws {
        let single = """
        {"id": "1001", "title": "单篇标题", "content": "正文……", "series": null}
        """
        let rules = ParseRule(
            bookList: nil, name: nil, author: nil, intro: nil, coverUrl: nil, bookUrl: nil,
            tocUrl: nil,
            chapterList: "$.novels",
            chapterName: "$.title",
            chapterUrl: "https://api.example.com/novel/{{$.id}}/cache",
            content: "$.content",
            nextPage: nil, replaceRegex: nil
        )
        let chapters = BookSourceEngine.parseChapters(
            body: single, base: URL(string: "https://api.example.com")!, rules: rules
        )
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters.first?.name, "单篇标题")
        XCTAssertEqual(chapters.first?.url, "https://api.example.com/novel/1001/cache")
    }

    // MARK: - 文本提取

    func testTextNodesOnlyDirectText() throws {
        let html = "<div>开头<b>子元素</b>结尾</div>"
        let text = RuleParser.getString(from: html, rule: "div@textnodes", baseURL: nil)
        XCTAssertEqual(text, "开头结尾")
    }

    func testNumericEntitiesDecoded() throws {
        let html = "<p>&#20320;&#22909; &amp; &#x4E16;&#x754C;</p>"
        let text = RuleParser.getString(from: html, rule: "p@text", baseURL: nil)
        XCTAssertEqual(text, "你好 & 世界")
    }
}
