import SwiftUI
import UIKit

/// Apple Books 风格封面
struct BookCoverView: View {
    let title: String
    let author: String
    let coverData: Data?
    var progress: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Group {
                    if let data = coverData, let ui = UIImage(data: data) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFill()
                    } else {
                        defaultCover
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                if progress > 0.01 && progress < 0.999 {
                    VStack {
                        Spacer()
                        GeometryReader { bar in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.15))
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: max(2, bar.size.width * progress))
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: PRTheme.coverCorner, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
            .overlay {
                RoundedRectangle(cornerRadius: PRTheme.coverCorner, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
            }
        }
        .aspectRatio(PRTheme.coverAspect, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title)，\(author)"))
    }

    private var defaultCover: some View {
        let palette = PRTheme.coverPalette(for: title)
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [palette.top, palette.bottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(0.18), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 10)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .minimumScaleFactor(0.75)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                Spacer(minLength: 0)
                if !author.isEmpty {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(12)
        }
    }
}

struct BookCard: View {
    let book: Book
    enum Style { case grid, list }
    var style: Style = .grid

    var body: some View {
        switch style {
        case .grid: gridCard
        case .list: listCard
        }
    }

    private var gridCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCoverView(
                title: book.title,
                author: book.author,
                coverData: book.coverImageData,
                progress: book.progressFraction
            )
            Text(book.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PRTheme.primaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !book.author.isEmpty {
                Text(book.author)
                    .font(.caption)
                    .foregroundStyle(PRTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private var listCard: some View {
        HStack(spacing: 14) {
            BookCoverView(
                title: book.title,
                author: book.author,
                coverData: book.coverImageData,
                progress: book.progressFraction
            )
            .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(book.groupDisplayName)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    if book.progressFraction > 0 {
                        Text("\(Int(book.progressFraction * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
