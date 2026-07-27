import SwiftUI
import UIKit

/// 一段划线在正文上的渲染描述。
///
/// 渲染层刻意不接收 `Bookmark`：它是 `@Model`，被 SwiftData 删除后再读属性会崩，
/// 且引用类型不参与 SwiftUI 的值 diff。调用方在边界处转成本值类型后，
/// 渲染层拿到的就是一份不会失效的快照。
struct HighlightSpan: Hashable {
    /// UTF-16 范围。跨到 `AttributedTextView` 之前由 `PageContent` 从
    /// 「章内绝对偏移」换算成「页内相对偏移」。
    let range: NSRange
    let color: Color

    init(range: NSRange, color: Color) {
        self.range = range
        self.color = color
    }

    // 手写而非依赖合成：NSRange 的 Hashable 由 Foundation overlay 提供，
    // 拆成两个 Int 参与哈希更稳妥，也让「划线是否变化」的判定语义一目了然。
    static func == (lhs: HighlightSpan, rhs: HighlightSpan) -> Bool {
        lhs.range.location == rhs.range.location
            && lhs.range.length == rhs.range.length
            && lhs.color == rhs.color
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(range.location)
        hasher.combine(range.length)
        hasher.combine(color)
    }
}

extension HighlightSpan {
    /// 书签模型 → 渲染快照。`@Model` 只在这一处被读取。
    @MainActor
    static func spans(from bookmarks: [Bookmark]) -> [HighlightSpan] {
        bookmarks.compactMap { bookmark in
            // 位置书签没有选区，不参与正文着色。
            guard bookmark.utf16Length > 0 else { return nil }
            return HighlightSpan(
                range: NSRange(
                    location: bookmark.utf16Location,
                    length: bookmark.utf16Length
                ),
                color: bookmark.color.tint
            )
        }
    }
}

/// 单页正文。正文使用原生 UITextView，以支持长按选取多个段落。
struct PageContent: View {
    let page: ReaderPage
    let background: BackgroundType
    let margin: MarginMode
    let bookTitle: String
    let chapterTitle: String
    let pageLabel: String
    let showHeader: Bool
    let showPageNumber: Bool
    /// 本章的划线，range 为**章内绝对偏移**（与 `ReaderPage.location` 同坐标系）。
    /// 给默认值以免现有调用方全部失效。
    var highlights: [HighlightSpan] = []
    var onSelection: (String, Int) -> Void
    var onTap: (CGFloat) -> Void

    /// 章内偏移 → 页内偏移。换算放在这里是因为只有 `PageContent` 知道 `page.location`；
    /// 跨页的划线在每一页各截一段，落在别页的部分会被 `NSIntersectionRange` 裁掉。
    private var pageHighlights: [HighlightSpan] {
        guard !highlights.isEmpty else { return [] }
        let pageRange = NSRange(location: page.location, length: page.length)
        return highlights.compactMap { highlight in
            let overlap = NSIntersectionRange(highlight.range, pageRange)
            guard overlap.length > 0 else { return nil }
            return HighlightSpan(
                range: NSRange(
                    location: overlap.location - page.location,
                    length: overlap.length
                ),
                color: highlight.color
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                HStack(spacing: 12) {
                    Text(bookTitle)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(chapterTitle)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(Color.readerSecondary(background))
                .frame(height: ReaderLayoutMetrics.headerHeight)
                .padding(.horizontal, margin.edgeInset)
                .padding(.top, margin.edgeInset)
            } else {
                Spacer().frame(height: margin.edgeInset)
            }

            AttributedTextView(
                attributedText: page.attributedText,
                highlights: pageHighlights,
                onSelection: { text, relativeOffset in
                    onSelection(text, page.location + relativeOffset)
                },
                onTap: onTap
            )
            .padding(.horizontal, margin.edgeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if showPageNumber {
                Text(pageLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.readerSecondary(background))
                    .frame(maxWidth: .infinity)
                    .frame(height: ReaderLayoutMetrics.footerHeight)
                    .padding(.bottom, margin.edgeInset)
            } else {
                Spacer().frame(height: margin.edgeInset)
            }
        }
    }
}

/// UIKit bridge for selectable, justified Core Text attributed strings.
struct AttributedTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    /// 已换算成**页内相对偏移**的划线；越界部分应由调用方裁剪。
    var highlights: [HighlightSpan] = []
    var onSelection: (String, Int) -> Void
    var onTap: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onTap: onTap)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onSelection = onSelection
        context.coordinator.onTap = onTap

        // 加了高亮后 textView.attributedText 不再等于传入的 attributedText，
        // 原来的「与 textView 现值比较」短路会永远判不相等、每帧重建整页富文本。
        // 改为记住上一次实际应用的**输入**（原文 + 划线），据此判断是否需要重建。
        let textChanged: Bool
        switch context.coordinator.appliedText {
        case .none:
            textChanged = true
        case .some(let applied):
            // 同一页反复求值时 page.attributedText 是同一个实例，
            // 先比指针可以省掉整页逐字符的属性比较。
            textChanged = applied !== attributedText && !applied.isEqual(to: attributedText)
        }
        let highlightsChanged = context.coordinator.appliedHighlights != highlights
        guard textChanged || highlightsChanged else { return }

        context.coordinator.appliedText = attributedText
        context.coordinator.appliedHighlights = highlights
        textView.attributedText = Self.decorated(attributedText, with: highlights)
    }

    /// 在原文副本上叠加划线底色。原始 `attributedText` 属于分页结果，是多页共享的
    /// 只读数据，不能就地修改。
    private static func decorated(
        _ source: NSAttributedString,
        with highlights: [HighlightSpan]
    ) -> NSAttributedString {
        guard !highlights.isEmpty else { return source }
        guard let mutable = source.mutableCopy() as? NSMutableAttributedString else {
            return source
        }
        let full = NSRange(location: 0, length: mutable.length)
        for highlight in highlights {
            // 调用方已裁剪过，这里再夹一次纯属防御：越界 range 会直接抛异常崩溃。
            let range = NSIntersectionRange(highlight.range, full)
            guard range.length > 0 else { continue }
            mutable.addAttribute(
                .backgroundColor,
                value: UIColor(highlight.color),
                range: range
            )
        }
        return mutable
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var onSelection: (String, Int) -> Void
        var onTap: (CGFloat) -> Void
        /// 上一次应用到 textView 的输入快照，用于跳过无变化的重建。
        var appliedText: NSAttributedString?
        var appliedHighlights: [HighlightSpan] = []

        init(
            onSelection: @escaping (String, Int) -> Void,
            onTap: @escaping (CGFloat) -> Void
        ) {
            self.onSelection = onSelection
            self.onTap = onTap
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            guard range.length > 0,
                  range.location != NSNotFound,
                  NSMaxRange(range) <= (textView.text as NSString).length
            else { return }
            onSelection((textView.text as NSString).substring(with: range), range.location)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let width = max(view.bounds.width, 1)
            onTap(recognizer.location(in: view).x / width)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
