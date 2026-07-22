import Foundation
import SwiftData

/// AI 改写历史：先写入再替换；支持撤销 / 收藏 / 分支
@Model
final class RewriteRecord {
    var id: UUID
    var bookID: UUID
    var chapterID: UUID
    var originalText: String
    var rewrittenText: String
    var userRequest: String
    var stylePresetRaw: String
    var timestamp: Date
    var originalUTF16Offset: Int
    var isUndone: Bool = false
    var isFavorite: Bool = false
    var branchLabel: String = ""

    init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        originalText: String,
        rewrittenText: String,
        userRequest: String,
        stylePreset: RewriteStylePreset = .default,
        timestamp: Date = Date(),
        originalUTF16Offset: Int = 0,
        isUndone: Bool = false,
        isFavorite: Bool = false,
        branchLabel: String = ""
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.originalText = originalText
        self.rewrittenText = rewrittenText
        self.userRequest = userRequest
        self.stylePresetRaw = stylePreset.rawValue
        self.timestamp = timestamp
        self.originalUTF16Offset = originalUTF16Offset
        self.isUndone = isUndone
        self.isFavorite = isFavorite
        self.branchLabel = branchLabel
    }

    var stylePreset: RewriteStylePreset {
        RewriteStylePreset(rawValue: stylePresetRaw) ?? .default
    }
}
