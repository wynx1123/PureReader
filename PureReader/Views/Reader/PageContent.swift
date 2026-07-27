import SwiftUI
import UIKit

/// 单页文本渲染（UILabel + NSAttributedString）
struct PageContent: View {
    let page: ReaderPage
    let background: BackgroundType
    let margin: MarginMode
    let pageLabel: String

    var body: some View {
        VStack(spacing: 0) {
            AttributedTextView(attributedText: page.attributedText)
                .padding(.horizontal, margin.edgeInset)
                .padding(.top, margin.edgeInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Text(pageLabel)
                .font(.caption2)
                .foregroundStyle(Color.readerSecondary(background))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
                .padding(.top, 4)
        }
    }
}

/// UIKit bridge for justified Core Text attributed strings
struct AttributedTextView: UIViewRepresentable {
    let attributedText: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = attributedText
    }
}
