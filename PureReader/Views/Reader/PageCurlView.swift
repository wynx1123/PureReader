import SwiftUI
import UIKit

/// 仿真翻页：UIPageViewController + pageCurl
struct PageCurlView: UIViewControllerRepresentable {
    let pages: [ReaderPage]
    @Binding var pageIndex: Int
    let background: BackgroundType
    let margin: MarginMode
    var onIndexChange: (Int) -> Void

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
                    label: "\(index + 1) / \(parent.pages.count)"
                )
                return hit
            }
            let vc = PageHostController()
            vc.index = index
            vc.apply(
                page: parent.pages[index],
                background: parent.background,
                margin: parent.margin,
                label: "\(index + 1) / \(parent.pages.count)"
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

final class PageHostController: UIViewController {
    var index: Int = 0
    private let textView = UITextView()
    private let pageLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0

        pageLabel.font = .preferredFont(forTextStyle: .caption2)
        pageLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [textView, pageLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pageLabel.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    func apply(page: ReaderPage, background: BackgroundType, margin: MarginMode, label: String) {
        if !isViewLoaded { loadViewIfNeeded() }
        let bg = UIColor(Color.readerBackground(background))
        view.backgroundColor = bg
        textView.attributedText = page.attributedText
        textView.textContainerInset = UIEdgeInsets(
            top: margin.edgeInset,
            left: margin.edgeInset,
            bottom: 0,
            right: margin.edgeInset
        )
        pageLabel.text = label
        pageLabel.textColor = UIColor(Color.readerSecondary(background))
    }
}
