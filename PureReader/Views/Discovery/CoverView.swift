import SwiftUI
import UIKit

/// 封面图加载组件：带防盗链请求头（如 i.pximg.net 需要 Referer），
/// 内存缓存 + 优雅降级为灰色书本占位。
/// 优先使用书源声明的 header；对 pximg 域名强制补充 Pixiv Referer，
/// 避免「有封面规则但显示 403 无图」。
struct CoverView: View {
    let url: String?
    var headers: [String: String] = [:]
    var width: CGFloat = 58
    var height: CGFloat = 78

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                }
                .task(id: url) {
                    await load()
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func load() async {
        guard let url,
              let target = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { return }
        if let cached = CoverCache.shared.image(for: url) {
            image = cached
            return
        }

        var request = URLRequest(url: target, timeoutInterval: 15)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        var merged = headers
        if target.host?.contains("pximg.net") == true, merged["Referer"] == nil {
            merged["Referer"] = "https://www.pixiv.net/"
        }
        for (name, value) in merged where request.value(forHTTPHeaderField: name) == nil {
            request.setValue(value, forHTTPHeaderField: name)
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              !data.isEmpty,
              let decoded = UIImage(data: data) else { return }
        CoverCache.shared.set(decoded, for: url)
        image = decoded
    }
}

/// 封面内存缓存（按 URL 去重，避免列表滚动重复下载）。
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 300
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
