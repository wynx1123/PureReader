import SwiftUI

extension View {
    /// 保证最小触控区域 44×44pt
    func minTapTarget(_ size: CGFloat = 44) -> some View {
        frame(minWidth: size, minHeight: size)
        .contentShape(Rectangle())
    }
}
