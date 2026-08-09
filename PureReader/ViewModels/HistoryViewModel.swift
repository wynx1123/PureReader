import Foundation
import SwiftData

/// 历史标签页的轻量 ViewModel。
///
/// 浏览历史直接复用 `Book.lastReadAt`（书一打开 `ReaderViewModel` 就会写入），
/// 因此不需要额外的浏览记录模型。「移出历史」只是清空该时间戳，
/// 不触碰书籍本体与阅读进度；再次打开该书时会重新进入历史。
@MainActor
@Observable
final class HistoryViewModel {
    var errorMessage: String?

    /// 把一本书移出历史（清空最后阅读时间）。
    func removeFromHistory(_ book: Book, context: ModelContext) {
        book.lastReadAt = nil
        do { try context.save() }
        catch { errorMessage = String(localized: "无法保存更改：\(error.localizedDescription)") }
    }

    /// 清空全部浏览历史。
    func clearAll(_ books: [Book], context: ModelContext) {
        for book in books where book.lastReadAt != nil {
            book.lastReadAt = nil
        }
        do { try context.save() }
        catch { errorMessage = String(localized: "无法清空历史：\(error.localizedDescription)") }
    }
}
