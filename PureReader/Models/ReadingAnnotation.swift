import Foundation
import SwiftData

// MARK: - ReadingAnnotation

/// 阅读标注（高亮、笔记、书签）。
@Model
final class ReadingAnnotation {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var chapterID: UUID?
    var chapterIndex: Int
    var selectedText: String
    var note: String
    var colorRaw: String
    var pageOffset: Int
    var createdAt: Date
    var updatedAt: Date

    var color: AnnotationColor {
        get { AnnotationColor(rawValue: colorRaw) ?? .yellow }
        set { colorRaw = newValue.rawValue }
    }

    var isBookmark: Bool {
        selectedText.isEmpty && note.isEmpty
    }

    var isHighlight: Bool {
        !selectedText.isEmpty && note.isEmpty
    }

    var isNote: Bool {
        !note.isEmpty
    }

    init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID? = nil,
        chapterIndex: Int = 0,
        selectedText: String = "",
        note: String = "",
        color: AnnotationColor = .yellow,
        pageOffset: Int = 0
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.chapterIndex = chapterIndex
        self.selectedText = selectedText
        self.note = note
        self.colorRaw = color.rawValue
        self.pageOffset = pageOffset
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - AnnotationColor

enum AnnotationColor: String, Codable, CaseIterable, Sendable {
    case yellow
    case green
    case blue
    case pink
    case purple
    case orange

    var displayName: String {
        switch self {
        case .yellow: return String(localized: "黄色")
        case .green: return String(localized: "绿色")
        case .blue: return String(localized: "蓝色")
        case .pink: return String(localized: "粉色")
        case .purple: return String(localized: "紫色")
        case .orange: return String(localized: "橙色")
        }
    }

    var swiftUIColor: String {
        switch self {
        case .yellow: return "yellow"
        case .green: return "green"
        case .blue: return "blue"
        case .pink: return "pink"
        case .purple: return "purple"
        case .orange: return "orange"
        }
    }
}

// MARK: - AnnotationService

/// 标注服务。
enum AnnotationService {

    /// 获取书籍的所有标注。
    @MainActor
    static func annotations(for bookID: UUID, context: ModelContext) -> [ReadingAnnotation] {
        let descriptor = FetchDescriptor<ReadingAnnotation>(
            predicate: #Predicate { $0.bookID == bookID },
            sortBy: [SortDescriptor(\.chapterIndex), SortDescriptor(\.pageOffset)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 获取章节的标注。
    @MainActor
    static func annotations(for bookID: UUID, chapterIndex: Int, context: ModelContext) -> [ReadingAnnotation] {
        let descriptor = FetchDescriptor<ReadingAnnotation>(
            predicate: #Predicate { $0.bookID == bookID && $0.chapterIndex == chapterIndex },
            sortBy: [SortDescriptor(\.pageOffset)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 添加书签。
    @MainActor
    @discardableResult
    static func addBookmark(
        bookID: UUID,
        chapterID: UUID? = nil,
        chapterIndex: Int,
        pageOffset: Int,
        context: ModelContext
    ) -> ReadingAnnotation {
        let annotation = ReadingAnnotation(
            bookID: bookID,
            chapterID: chapterID,
            chapterIndex: chapterIndex,
            pageOffset: pageOffset
        )
        context.insert(annotation)
        try? context.save()
        return annotation
    }

    /// 添加高亮。
    @MainActor
    @discardableResult
    static func addHighlight(
        bookID: UUID,
        chapterID: UUID?,
        chapterIndex: Int,
        text: String,
        color: AnnotationColor = .yellow,
        pageOffset: Int = 0,
        context: ModelContext
    ) -> ReadingAnnotation {
        let annotation = ReadingAnnotation(
            bookID: bookID,
            chapterID: chapterID,
            chapterIndex: chapterIndex,
            selectedText: text,
            color: color,
            pageOffset: pageOffset
        )
        context.insert(annotation)
        try? context.save()
        return annotation
    }

    /// 添加笔记。
    @MainActor
    @discardableResult
    static func addNote(
        bookID: UUID,
        chapterID: UUID?,
        chapterIndex: Int,
        selectedText: String = "",
        note: String,
        color: AnnotationColor = .yellow,
        pageOffset: Int = 0,
        context: ModelContext
    ) -> ReadingAnnotation {
        let annotation = ReadingAnnotation(
            bookID: bookID,
            chapterID: chapterID,
            chapterIndex: chapterIndex,
            selectedText: selectedText,
            note: note,
            color: color,
            pageOffset: pageOffset
        )
        context.insert(annotation)
        try? context.save()
        return annotation
    }

    /// 删除标注。
    @MainActor
    static func delete(_ annotation: ReadingAnnotation, context: ModelContext) {
        context.delete(annotation)
        try? context.save()
    }

    /// 更新笔记内容。
    @MainActor
    static func updateNote(_ annotation: ReadingAnnotation, note: String, context: ModelContext) {
        annotation.note = note
        annotation.updatedAt = Date()
        try? context.save()
    }

    /// 删除书籍的所有标注。
    @MainActor
    static func deleteAll(for bookID: UUID, context: ModelContext) {
        let annotations = Self.annotations(for: bookID, context: context)
        for annotation in annotations {
            context.delete(annotation)
        }
        try? context.save()
    }
}