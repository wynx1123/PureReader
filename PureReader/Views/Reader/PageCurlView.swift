import SwiftUI
import UIKit

/// 仿真翻页：UIPageViewController + pageCurl
struct PageCurlView: UIViewControllerRepresentable {
    let pages: [ReaderPage]
    @Binding var pageIndex: Int
    let background: BackgroundType
    let margin: MarginMode
    let bookTitle: String
    let chapterTitle: String
    let showHeader: Bool
    let showPageNumber: Bool
    let canGoToPreviousChapter: Bool
    let canGoToNextChapter: Bool
    /// 当前章的划线，章内绝对偏移。
    var highlights: [HighlightSpan] = []
    var onIndexChange: (Int) -> Void
    var onPreviousChapter: () -> Void
    var onNextChapter: () -> Void
    var onSelection: (String, Int) -> Void
    var onTap: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.isDoubleSided = false
        context.coordinator.parent = self
        context.coordinator.invalidateCacheIfNeeded(for: pages, highlights: highlights)
        if let vc = context.coordinator.controller(for: pageIndex) {
            pvc.setViewControllers([vc], direction: .forward, animated: false)
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // 换章 / 重新分页后旧的 host controller 仍持有失效的下标，必须先丢弃缓存，
        // 否则复用到的 controller 会按旧下标去索引新的 pages 数组。
        context.coordinator.invalidateCacheIfNeeded(for: pages, highlights: highlights)
        let target = context.coordinator.controller(for: pageIndex)
        // 外部 pageIndex 变化时同步
        if let current = pvc.viewControllers?.first as? PageHostController,
           current.index != pageIndex,
           let target {
            let direction: UIPageViewController.NavigationDirection =
                pageIndex >= current.index ? .forward : .reverse
            pvc.setViewControllers([target], direction: direction, animated: true)
        } else if pvc.viewControllers?.isEmpty != false,
                  let target {
            pvc.setViewControllers([target], direction: .forward, animated: false)
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlView
        private var cache: [Int: PageHostController] = [:]
        /// 当前缓存对应的分页结果标识（页数 + 首尾页在章节中的偏移）。
        private var cacheToken: [Int]?
        /// 缓存上限，避免长章节常驻数百个 UITextView。
        private let maxCachedControllers = 8

        init(_ parent: PageCurlView) {
            self.parent = parent
        }

        private func token(for pages: [ReaderPage], highlights: [HighlightSpan]) -> [Int] {
            // 划线变化也要让缓存失效：已在屏上的 controller 不会自己重新 apply，
            // 不清缓存的话新加的划线要等翻页才显示。
            var value = [pages.count, pages.first?.location ?? -1, pages.last?.location ?? -1]
            value.append(highlights.count)
            for span in highlights {
                value.append(span.range.location)
                value.append(span.range.length)
            }
            return value
        }

        func invalidateCacheIfNeeded(for pages: [ReaderPage], highlights: [HighlightSpan]) {
            let current = token(for: pages, highlights: highlights)
            guard cacheToken != current else { return }
            cacheToken = current
            cache.removeAll()
        }

        private func store(_ controller: PageHostController, at index: Int) {
            if cache.count >= maxCachedControllers,
               let victim = cache.keys.max(by: { abs($0 - index) < abs($1 - index) }),
               victim != index {
                cache.removeValue(forKey: victim)
            }
            cache[index] = controller
        }

        func controller(for index: Int) -> PageHostController? {
            if index == -1, parent.canGoToPreviousChapter {
                let vc = cache[index] ?? PageHostController()
                vc.index = index
                vc.applyBoundary(
                    title: String(localized: "上一章"),
                    background: parent.background,
                    systemImage: "chevron.left.2"
                )
                store(vc, at: index)
                return vc
            }
            if index == parent.pages.count, parent.canGoToNextChapter {
                let vc = cache[index] ?? PageHostController()
                vc.index = index
                vc.applyBoundary(
                    title: String(localized: "下一章"),
                    background: parent.background,
                    systemImage: "chevron.right.2"
                )
                store(vc, at: index)
                return vc
            }
            guard parent.pages.indices.contains(index) else { return nil }

            let page = parent.pages[index]
            // 按值捕获本页在章节中的偏移。若捕获 index 再回头索引 parent.pages，
            // 换章后该下标可能已越界。
            let pageLocation = page.location
            let vc = cache[index] ?? PageHostController()
            vc.index = index
            vc.apply(
                page: page,
                background: parent.background,
                margin: parent.margin,
                bookTitle: parent.bookTitle,
                chapterTitle: parent.chapterTitle,
                label: "\(index + 1) / \(parent.pages.count)",
                showHeader: parent.showHeader,
                showPageNumber: parent.showPageNumber,
                highlights: parent.highlights,
                onSelection: { [weak self] text, relativeOffset in
                    self?.parent.onSelection(text, pageLocation + relativeOffset)
                },
                onTap: parent.onTap
            )
            store(vc, at: index)
            return vc
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let host = viewController as? PageHostController else { return nil }
            return controller(for: host.index - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let host = viewController as? PageHostController else { return nil }
            return controller(for: host.index + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  let host = pageViewController.viewControllers?.first as? PageHostController
            else { return }
            if host.index < 0 {
                parent.onPreviousChapter()
                return
            }
            if host.index >= parent.pages.count {
                parent.onNextChapter()
                return
            }
            parent.pageIndex = host.index
            parent.onIndexChange(host.index)
        }
    }
}

final class PageHostController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {
    var index: Int = 0
    private let textView = UITextView()
    private let headerLabel = UILabel()
    private let pageLabel = UILabel()
    private var topConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?
    private var headerHeightConstraint: NSLayoutConstraint?
    private var footerHeightConstraint: NSLayoutConstraint?
    private var selectionHandler: ((String, Int) -> Void)?
    private var tapHandler: ((CGFloat) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        textView.addGestureRecognizer(tap)

        headerLabel.font = .preferredFont(forTextStyle: .caption2)
        headerLabel.numberOfLines = 1
        pageLabel.font = .preferredFont(forTextStyle: .caption2)
        pageLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [headerLabel, textView, pageLabel])
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        topConstraint = stack.topAnchor.constraint(equalTo: view.topAnchor)
        bottomConstraint = stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        headerHeightConstraint = headerLabel.heightAnchor.constraint(
            equalToConstant: ReaderLayoutMetrics.headerHeight
        )
        footerHeightConstraint = pageLabel.heightAnchor.constraint(
            equalToConstant: ReaderLayoutMetrics.footerHeight
        )
        NSLayoutConstraint.activate([
            topConstraint!,
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint!,
            headerHeightConstraint!,
            footerHeightConstraint!
        ])
    }

    func apply(
        page: ReaderPage,
        background: BackgroundType,
        margin: MarginMode,
        bookTitle: String,
        chapterTitle: String,
        label: String,
        showHeader: Bool,
        showPageNumber: Bool,
        highlights: [HighlightSpan] = [],
        onSelection: @escaping (String, Int) -> Void,
        onTap: @escaping (CGFloat) -> Void
    ) {
        if !isViewLoaded { loadViewIfNeeded() }
        let bg = UIColor(Color.readerBackground(background))
        view.backgroundColor = bg
        textView.attributedText = Self.applyingHighlights(
            highlights,
            to: page.attributedText,
            pageLocation: page.location
        )
        textView.textContainerInset = UIEdgeInsets(
            top: 0,
            left: margin.edgeInset,
            bottom: 0,
            right: margin.edgeInset
        )
        topConstraint?.constant = margin.edgeInset
        bottomConstraint?.constant = -margin.edgeInset
        headerLabel.text = chapterTitle.isEmpty ? bookTitle : "\(bookTitle) · \(chapterTitle)"
        headerLabel.textColor = UIColor(Color.readerSecondary(background))
        headerLabel.layer.sublayerTransform = CATransform3DMakeTranslation(
            margin.edgeInset,
            0,
            0
        )
        headerLabel.isHidden = !showHeader
        headerHeightConstraint?.constant = showHeader ? ReaderLayoutMetrics.headerHeight : 0
        pageLabel.text = label
        pageLabel.textColor = UIColor(Color.readerSecondary(background))
        pageLabel.isHidden = !showPageNumber
        footerHeightConstraint?.constant = showPageNumber ? ReaderLayoutMetrics.footerHeight : 0
        selectionHandler = onSelection
        tapHandler = onTap
    }

    /// 把章内绝对偏移的划线换算成页内偏移并叠加底色。
    /// 与 PageContent 的处理保持一致；无划线时直接返回原串，不做多余拷贝。
    private static func applyingHighlights(
        _ highlights: [HighlightSpan],
        to text: NSAttributedString,
        pageLocation: Int
    ) -> NSAttributedString {
        guard !highlights.isEmpty else { return text }
        let pageRange = NSRange(location: pageLocation, length: text.length)
        let mutable = NSMutableAttributedString(attributedString: text)
        for span in highlights {
            let intersection = NSIntersectionRange(span.range, pageRange)
            guard intersection.length > 0 else { continue }
            mutable.addAttribute(
                .backgroundColor,
                value: UIColor(span.color),
                range: NSRange(
                    location: intersection.location - pageLocation,
                    length: intersection.length
                )
            )
        }
        return mutable
    }

    func applyBoundary(
        title: String,
        background: BackgroundType,
        systemImage: String
    ) {
        if !isViewLoaded { loadViewIfNeeded() }
        let color = UIColor(Color.readerSecondary(background))
        let attachment = NSTextAttachment()
        attachment.image = UIImage(systemName: systemImage)?.withTintColor(color)
        let content = NSMutableAttributedString(attachment: attachment)
        content.append(NSAttributedString(string: "\n\n\(title)"))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        content.addAttributes(
            [
                .font: UIFont.preferredFont(forTextStyle: .headline),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ],
            range: NSRange(location: 0, length: content.length)
        )

        view.backgroundColor = UIColor(Color.readerBackground(background))
        textView.attributedText = content
        textView.textContainerInset = UIEdgeInsets(top: 120, left: 24, bottom: 0, right: 24)
        topConstraint?.constant = 0
        bottomConstraint?.constant = 0
        headerLabel.isHidden = true
        pageLabel.isHidden = true
        headerHeightConstraint?.constant = 0
        footerHeightConstraint?.constant = 0
        selectionHandler = nil
        tapHandler = nil
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        let range = textView.selectedRange
        guard range.length > 0,
              range.location != NSNotFound,
              NSMaxRange(range) <= (textView.text as NSString).length
        else { return }
        selectionHandler?((textView.text as NSString).substring(with: range), range.location)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let view = recognizer.view else { return }
        tapHandler?(recognizer.location(in: view).x / max(view.bounds.width, 1))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
