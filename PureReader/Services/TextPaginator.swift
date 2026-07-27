import Foundation
import UIKit
import CoreText

/// Core Text 分页结果
struct ReaderPage: Identifiable, Hashable {
    let id: Int
    /// 在章节全文中的起始 UTF-16 偏移
    let location: Int
    let length: Int
    let attributedText: NSAttributedString

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(location)
        hasher.combine(length)
    }

    static func == (lhs: ReaderPage, rhs: ReaderPage) -> Bool {
        lhs.id == rhs.id && lhs.location == rhs.location && lhs.length == rhs.length
    }
}

/// 使用 Core Text 按给定版心将章节文本切分为页
enum TextPaginator {

    struct Layout: Hashable {
        var fontSize: CGFloat
        var lineSpacing: CGFloat
        var margin: MarginMode
        var contentSize: CGSize
        var isDark: Bool

        init(
            fontSize: Double,
            lineSpacing: Double,
            margin: MarginMode,
            contentSize: CGSize,
            isDark: Bool
        ) {
            self.fontSize = CGFloat(fontSize)
            self.lineSpacing = CGFloat(lineSpacing)
            self.margin = margin
            self.contentSize = contentSize
            self.isDark = isDark
        }
    }

    static func clearCache() {
        // reserved
    }

    /// 同步分页（建议在后台队列调用）
    static func paginate(
        chapterID: String,
        text: String,
        layout: Layout
    ) -> [ReaderPage] {
        _ = chapterID
        let inset = layout.margin.edgeInset
        let pageWidth = max(1, layout.contentSize.width - inset * 2)
        let pageHeight = max(1, layout.contentSize.height - inset * 2)
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard !text.isEmpty else {
            let empty = NSAttributedString(string: "")
            return [ReaderPage(id: 0, location: 0, length: 0, attributedText: empty)]
        }

        let attr = makeAttributedString(text: text, layout: layout)
        let fullRange = CFRange(location: 0, length: attr.length)
        let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)

        var pages: [ReaderPage] = []
        var location = 0
        var pageIndex = 0

        while location < attr.length {
            let path = CGPath(rect: pageRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            var length = visible.length
            if length <= 0 {
                // 兜底：至少推进一个字符，避免死循环
                length = 1
            }
            if location + length > attr.length {
                length = attr.length - location
            }
            if length <= 0 { break }

            let slice = attr.attributedSubstring(from: NSRange(location: location, length: length))
            pages.append(
                ReaderPage(
                    id: pageIndex,
                    location: location,
                    length: length,
                    attributedText: slice
                )
            )
            location += length
            pageIndex += 1

            // 安全上限，防止异常文本卡死
            if pageIndex > 50_000 { break }
            _ = fullRange
        }

        if pages.isEmpty {
            pages = [ReaderPage(id: 0, location: 0, length: attr.length, attributedText: attr)]
        }
        return pages
    }

    static func pageIndex(forCharacterOffset offset: Int, in pages: [ReaderPage]) -> Int {
        guard !pages.isEmpty else { return 0 }
        if offset <= pages[0].location { return 0 }
        for (i, page) in pages.enumerated() {
            let end = page.location + page.length
            if offset < end { return i }
        }
        return pages.count - 1
    }

    private static func makeAttributedString(text: String, layout: Layout) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: layout.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = layout.lineSpacing
        paragraph.alignment = .justified
        paragraph.lineBreakMode = .byWordWrapping
        let color = layout.isDark ? UIColor.white : UIColor.black
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }
}
