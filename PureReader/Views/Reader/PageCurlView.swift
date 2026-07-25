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
    var onIndexChange: (Int) -> Void
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
        if let vc = context.coordinator.controller(for: pageIndex) {
            pvc.setViewControllers([vc], direction: .forward, animated: false)
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // 外部 pageIndex 变化时同步
        if let current = pvc.viewControllers?.first as? PageHostController,
           current.index != pageIndex,
           let vc = context.coordinator.controller(for: pageIndex) {
            let direction: UIPageViewController.NavigationDirection =
                pageIndex >= current.index ? .forward : .reverse
            pvc.setViewControllers([vc], direction: direction, animated: true)
        } else if pvc.viewControllers?.isEmpty != false,
                  let vc = context.coordinator.controller(for: pageIndex) {
            pvc.setViewControllers([vc], direction: .forward, animated: false)
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlView
        private var cache: [Int: PageHostController] = [:]

        init(_ parent: PageCurlView) {
            self.parent = parent
        }

        func controller(for index: Int) -> PageHostController? {
            guard parent.pages.indices.contains(index) else { return nil }
            if let hit = cache[index] {
                hit.apply(
                    page: parent.pages[index],
                    background: parent.background,
                    margin: parent.margin,
                    bookTitle: parent.bookTitle,
                    chapterTitle: parent.chapterTitle,
                    label: "\(index + 1) / \(parent.pages.count)",
                    showHeader: parent.showHeader,
                    showPageNumber: parent.showPageNumber,
                    onSelection: { [weak self] text, relativeOffset in
                        guard let self else { return }
                        self.parent.onSelection(text, self.parent.pages[index].location + relativeOffset)
                    },
                    onTap: parent.onTap
                )
                return hit
            }
            let vc = PageHostController()
            vc.index = index
            vc.apply(
                page: parent.pages[index],
                background: parent.background,
                margin: parent.margin,
                bookTitle: parent.bookTitle,
                chapterTitle: parent.chapterTitle,
                label: "\(index + 1) / \(parent.pages.count)",
                showHeader: parent.showHeader,
                showPageNumber: parent.showPageNumber,
                onSelection: { [weak self] text, relativeOffset in
                    guard let self else { return }
                    self.parent.onSelection(text, self.parent.pages[index].location + relativeOffset)
                },
                onTap: parent.onTap
            )
            cache[index] = vc
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
        onSelection: @escaping (String, Int) -> Void,
        onTap: @escaping (CGFloat) -> Void
    ) {
        if !isViewLoaded { loadViewIfNeeded() }
        let bg = UIColor(Color.readerBackground(background))
        view.backgroundColor = bg
        textView.attributedText = page.attributedText
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
