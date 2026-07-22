import SwiftUI

struct ReaderTextureBackground: View {
    let type: BackgroundType

    var body: some View {
        ZStack {
            Color.readerBackground(type)

            switch type {
            case .paperTexture:
                paperNoise
            case .parchment:
                parchmentLayers
            default:
                EmptyView()
            }
        }
        .ignoresSafeArea()
    }

    private var paperNoise: some View {
        Canvas { context, size in
            // 轻噪声点 + 细横纹模拟纸感
            for _ in 0..<Int(size.width * size.height / 900) {
                let x = CGFloat.random(in: 0..<size.width)
                let y = CGFloat.random(in: 0..<size.height)
                let r = CGFloat.random(in: 0.3...1.1)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                    with: .color(.black.opacity(0.035))
                )
            }
            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(.brown.opacity(0.03)), lineWidth: 0.5)
                y += 6
            }
        }
        .allowsHitTesting(false)
    }

    private var parchmentLayers: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.88, blue: 0.70),
                    Color(red: 0.86, green: 0.74, blue: 0.52),
                    Color(red: 0.90, green: 0.80, blue: 0.58)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.multiply)
            .opacity(0.35)

            RadialGradient(
                colors: [
                    .clear,
                    Color.brown.opacity(0.12)
                ],
                center: .center,
                startRadius: 40,
                endRadius: 420
            )

            // 边缘暗角
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [.clear, .black.opacity(0.08)],
                        center: .center,
                        startRadius: 100,
                        endRadius: 500
                    )
                )
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func readerBackground(_ type: BackgroundType) -> some View {
        background {
            ReaderTextureBackground(type: type)
        }
    }
}
