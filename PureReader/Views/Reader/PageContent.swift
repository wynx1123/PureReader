import SwiftUI
import UIKit

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
    var onSelection: (String, Int) -> Void
    var onTap: (CGFloat) -> Void

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
        if !textView.attributedText.isEqual(to: attributedText) {
            textView.attributedText = attributedText
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var onSelection: (String, Int) -> Void
        var onTap: (CGFloat) -> Void

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
