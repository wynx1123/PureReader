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
        /// 行距「倍数」（设置页滑块的 1.2~2.5），不是 pt；真正下发给排版的值见 resolvedLineSpacing。
        var lineSpacing: CGFloat
        var margin: MarginMode
        var contentSize: CGSize
        var isDark: Bool
        var showHeader: Bool
        var showPageNumber: Bool
        /// 首行缩进字符数，随字号缩放才能在任意字号下都缩进「两个字」。
        var firstLineIndentChars: CGFloat
        /// 段间距相对字号的倍数，同样随字号缩放以保持视觉比例。
        var paragraphSpacingRatio: CGFloat

        /// NSParagraphStyle.lineSpacing 是「行与行之间额外增加的 pt」，
        /// 而设置页给的是倍数，直接赋值会让 1.2~2.5 只差 1.3pt，看起来像滑块坏了。
        var resolvedLineSpacing: CGFloat {
            max(0, fontSize * (lineSpacing - 1))
        }

        init(
            fontSize: Double,
            lineSpacing: Double,
            margin: MarginMode,
            contentSize: CGSize,
            isDark: Bool,
            showHeader: Bool,
            showPageNumber: Bool,
            // 新增项给默认值，避免破坏既有调用方
            firstLineIndentChars: Double = 2,
            paragraphSpacingRatio: Double = 0.35
        ) {
            self.fontSize = CGFloat(fontSize)
            self.lineSpacing = CGFloat(lineSpacing)
            self.margin = margin
            self.contentSize = contentSize
            self.isDark = isDark
            self.showHeader = showHeader
            self.showPageNumber = showPageNumber
            self.firstLineIndentChars = CGFloat(max(0, firstLineIndentChars))
            self.paragraphSpacingRatio = CGFloat(max(0, paragraphSpacingRatio))
        }
    }

    /// 同步分页（建议在后台队列调用）
    static func paginate(
        chapterID: String,
        text: String,
        richContentData: Data? = nil,
        layout: Layout
    ) -> [ReaderPage] {
        _ = chapterID
        let inset = layout.margin.edgeInset
        let pageWidth = max(1, layout.contentSize.width - inset * 2)
        let decorationHeight = (layout.showHeader ? ReaderLayoutMetrics.headerHeight : 0)
            + (layout.showPageNumber ? ReaderLayoutMetrics.footerHeight : 0)
        let pageHeight = max(1, layout.contentSize.height - inset * 2 - decorationHeight)
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard !text.isEmpty else {
            let empty = NSAttributedString(string: "")
            return [ReaderPage(id: 0, location: 0, length: 0, attributedText: empty)]
        }

        let attr = makeAttributedString(
            text: text,
            richContentData: richContentData,
            layout: layout,
            maximumImageWidth: pageWidth,
            maximumImageHeight: pageHeight * 0.72
        )
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

    private static func makeAttributedString(
        text: String,
        richContentData: Data?,
        layout: Layout,
        maximumImageWidth: CGFloat,
        maximumImageHeight: CGFloat
    ) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: layout.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = layout.resolvedLineSpacing
        paragraph.firstLineHeadIndent = layout.fontSize * layout.firstLineIndentChars
        paragraph.paragraphSpacing = layout.fontSize * layout.paragraphSpacingRatio
        paragraph.alignment = .natural
        paragraph.lineBreakMode = .byWordWrapping
        let color = layout.isDark ? UIColor.white : UIColor.black
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let result = NSMutableAttributedString(string: text, attributes: attrs)
        guard let rich = ChapterRichContent.decode(richContentData) else { return result }

        for inlineImage in rich.images {
            let range = NSRange(location: inlineImage.utf16Location, length: 1)
            guard NSMaxRange(range) <= result.length,
                  (result.string as NSString).substring(with: range)
                    == ChapterRichContent.imagePlaceholder,
                  let image = UIImage(data: inlineImage.data),
                  image.size.width > 0,
                  image.size.height > 0
            else { continue }

            let scale = min(
                1,
                maximumImageWidth / image.size.width,
                maximumImageHeight / image.size.height
            )
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0,
                y: -layout.fontSize * 0.2,
                width: floor(image.size.width * scale),
                height: floor(image.size.height * scale)
            )
            let replacement = NSMutableAttributedString(
                attributedString: NSAttributedString(attachment: attachment)
            )
            let imageParagraph = paragraph.mutableCopy() as? NSMutableParagraphStyle
            imageParagraph?.alignment = .center
            // 图片自成一段并居中，继承正文首行缩进会让它偏离中线
            imageParagraph?.firstLineHeadIndent = 0
            if let imageParagraph {
                replacement.addAttribute(
                    .paragraphStyle,
                    value: imageParagraph,
                    range: NSRange(location: 0, length: replacement.length)
                )
            }
            result.replaceCharacters(in: range, with: replacement)
        }
        return result
    }
}

struct BookPageID: Hashable, Sendable {
    let chapterIndex: Int
    let pageIndex: Int
}

struct BookReaderPage: Identifiable, Hashable {
    let id: BookPageID
    let chapterTitle: String
    let page: ReaderPage
    let chapterPageCount: Int
}

enum ReaderLayoutMetrics {
    static let headerHeight: CGFloat = 24
    static let footerHeight: CGFloat = 24
}
