import Foundation
import SwiftData
import UniformTypeIdentifiers

/// 无状态导入服务：安全作用域 → 沙盒副本 → 解析 → SwiftData
enum BookImportService {
    static let maxFileBytes = 50 * 1024 * 1024

    // MARK: - Public parse

    /// 在后台暂存到 App Caches。调用方必须在整个 await 期间保持 security scope。
    static func stageSecurityScopedFileAsync(_ url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try stageSecurityScopedFile(url)
        }.value
    }

    /// 同步暂存实现，只在后台任务中调用，避免 iCloud 下载和协调读取阻塞主线程。
    static func stageSecurityScopedFile(_ url: URL) throws -> URL {
        let fm = FileManager.default
        if let sourceValues = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .fileSizeKey]
        ) {
            // File Provider 的云端占位文件在完成协调读取前，isRegularFile 可能错误地
            // 报告为 false。这里只明确拒绝目录，文件类型交给实际读取与解析判断。
            if sourceValues.isDirectory == true {
                throw ImportError.unsupportedFormat
            }
            if let size = sourceValues.fileSize, size > maxFileBytes {
                throw ImportError.fileTooLarge
            }
        }

        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw ImportError.unreadableFile(String(localized: "无法取得 App 缓存目录"))
        }
        let dir = caches.appendingPathComponent("Imports", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ImportError.unreadableFile(error.localizedDescription)
        }

        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedName = ext.isEmpty
            ? UUID().uuidString
            : "\(UUID().uuidString).\(ext)"
        let destination = dir.appendingPathComponent(stagedName)
        var coordinationError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: url,
            options: [.withoutChanges],
            error: &coordinationError
        ) { readableURL in
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                do {
                    try fm.copyItem(at: readableURL, to: destination)
                } catch {
                    // 部分 iCloud/第三方 Provider 不允许复制其协调 URL，但允许读取。
                    // 在协调回调内读取会触发占位文件下载，再写入 App 自己的缓存。
                    let data = try Data(contentsOf: readableURL, options: [.mappedIfSafe])
                    guard !data.isEmpty else { throw ImportError.emptyFile }
                    guard data.count <= maxFileBytes else { throw ImportError.fileTooLarge }
                    try data.write(to: destination, options: .atomic)
                }
            } catch {
                copyError = error
            }
        }

        if copyError != nil || !fm.fileExists(atPath: destination.path) {
            // Files 提供者偶尔不支持协调复制；仅在当前安全作用域内用 Data 兜底。
            do {
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard !data.isEmpty else { throw ImportError.emptyFile }
                guard data.count <= maxFileBytes else { throw ImportError.fileTooLarge }
                try data.write(to: destination, options: .atomic)
            } catch let error as ImportError {
                throw error
            } catch {
                throw ImportError.accessDenied(error.localizedDescription)
            }
        }
        if !fm.fileExists(atPath: destination.path), let coordinationError {
            throw ImportError.accessDenied(coordinationError.localizedDescription)
        }
        guard fm.fileExists(atPath: destination.path) else {
            throw ImportError.accessDenied(String(localized: "未能将所选文件复制到 App"))
        }
        if let stagedValues = try? destination.resourceValues(forKeys: [.fileSizeKey]),
           let stagedSize = stagedValues.fileSize,
           stagedSize > maxFileBytes {
            try? fm.removeItem(at: destination)
            throw ImportError.fileTooLarge
        }
        return destination
    }

    /// 已在 App 沙盒中的文件：后台读取和解析，避免文件导入完成后 UI 停滞。
    static func parseStagedFile(
        url: URL,
        originalFilename: String? = nil
    ) async throws -> ParsedBook {
        try await Task.detached(priority: .userInitiated) {
            try parseSandboxFile(url: url, originalFilename: originalFilename)
        }.value
    }

    /// 已在 App 沙盒内的路径（副本）
    static func parseSandboxFile(
        url: URL,
        originalFilename: String? = nil
    ) throws -> ParsedBook {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
        if let size = values.fileSize, size > maxFileBytes {
            throw ImportError.fileTooLarge
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ImportError.unreadableFile(error.localizedDescription)
        }
        if data.isEmpty { throw ImportError.emptyFile }

        let sourceName = originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = sourceName.isEmpty ? url.lastPathComponent : sourceName
        let displayURL = URL(fileURLWithPath: displayName)
        let ext = displayURL.pathExtension.lowercased()
        let preferred = displayURL.deletingPathExtension().lastPathComponent
            .removingPercentEncoding ?? displayURL.deletingPathExtension().lastPathComponent

        switch ext {
        case "txt", "text", "md", "log", "csv":
            return try TXTParser.parse(data: data, preferredTitle: preferred)
        case "epub":
            return try EPUBParser.parse(data: data, preferredTitle: preferred)
        default:
            // 嗅探
            if data.starts(with: [0x50, 0x4B]) {
                // ZIP → 尝试 EPUB
                do {
                    return try EPUBParser.parse(data: data, preferredTitle: preferred)
                } catch {
                    throw ImportError.epubInvalid
                }
            }
            // 无扩展名 / 其它：按文本尝试
            do {
                return try TXTParser.parse(data: data, preferredTitle: preferred)
            } catch {
                if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                    if type.conforms(to: .plainText) || type.conforms(to: .text) {
                        throw error
                    }
                    if type.identifier.contains("epub") {
                        throw ImportError.epubInvalid
                    }
                }
                throw ImportError.unsupportedFormat
            }
        }
    }

    static func parseRemoteURL(_ string: String) async throws -> ParsedBook {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased() else {
            throw ImportError.invalidURL
        }
        guard scheme == "https" else {
            throw ImportError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("PureReader/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await downloadWithRetry(request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ImportError.downloadFailed(String(localized: "HTTP 状态异常"))
        }
        if data.count > maxFileBytes { throw ImportError.fileTooLarge }
        if data.isEmpty { throw ImportError.emptyFile }

        let rawName = url.deletingPathExtension().lastPathComponent
        let name = rawName.removingPercentEncoding ?? rawName
        let ext = url.pathExtension.lowercased()
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        if ext == "epub" || mime.contains("epub") {
            return try EPUBParser.parse(data: data, preferredTitle: name)
        }
        if ["txt", "text", "md"].contains(ext)
            || mime.contains("text/plain")
            || mime.contains("charset")
            || mime.contains("text/") {
            return try TXTParser.parse(data: data, preferredTitle: name)
        }
        if data.starts(with: [0x50, 0x4B]) {
            return try EPUBParser.parse(data: data, preferredTitle: name)
        }
        return try TXTParser.parse(data: data, preferredTitle: name)
    }

    private static func downloadWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await URLSession.shared.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
                }
            }
        }
        throw ImportError.downloadFailed(lastError?.localizedDescription ?? String(localized: "网络错误"))
    }

    // MARK: - Persist

    @MainActor
    @discardableResult
    static func save(
        parsed: ParsedBook,
        sourceType: SourceType,
        sourceURL: String?,
        group: String?,
        tags: [String],
        into context: ModelContext
    ) throws -> Book {
        guard !parsed.chapters.isEmpty else {
            throw ImportError.emptyFile
        }

        let book = Book(
            title: parsed.title.isEmpty ? String(localized: "未命名") : parsed.title,
            author: parsed.author,
            coverImageData: parsed.coverImageData,
            sourceType: sourceType,
            sourceURL: sourceURL,
            format: parsed.format,
            totalChapters: parsed.chapters.count,
            group: group,
            tags: tags
        )

        context.insert(book)

        let orderedChapters = parsed.chapters.sorted { $0.index < $1.index }
        var chapterModels: [Chapter] = []
        chapterModels.reserveCapacity(orderedChapters.count)
        for (normalizedIndex, pc) in orderedChapters.enumerated() {
            let ch = Chapter(
                index: normalizedIndex,
                title: pc.title.isEmpty ? String(localized: "第 \(normalizedIndex + 1) 章") : pc.title,
                content: pc.content.isEmpty ? " " : pc.content,
                richContentData: pc.richContentData
            )
            ch.book = book
            chapterModels.append(ch)
            context.insert(ch)
        }
        book.chapters = chapterModels
        book.filePath = "swiftdata://\(book.id.uuidString)"

        do {
            try context.save()
        } catch {
            for chapter in chapterModels {
                context.delete(chapter)
            }
            context.delete(book)
            throw ImportError.saveFailed(error.localizedDescription)
        }

        do {
            try updateKnownTags(tags, context: context)
        } catch {
            // The book itself was already committed, so don't report an import
            // failure that would invite a duplicate retry. The tag index is
            // auxiliary; make the persistence problem visible to diagnostics.
            assertionFailure("Failed to update known tags: \(error)")
        }
        return book
    }

    @MainActor
    private static func updateKnownTags(_ tags: [String], context: ModelContext) throws {
        guard !tags.isEmpty else { return }
        let descriptor = FetchDescriptor<ShelfPreferences>()
        let prefs = (try? context.fetch(descriptor))?.first
        let target: ShelfPreferences
        if let prefs {
            target = prefs
        } else {
            target = ShelfPreferences()
            context.insert(target)
        }
        var set = Set(target.knownTags)
        for t in tags where !t.isEmpty { set.insert(t) }
        target.knownTags = set.sorted()
        try context.save()
    }

    @MainActor
    static func deleteBook(_ book: Book, context: ModelContext) throws {
        // 清理改写历史
        let bid = book.id
        let descriptor = FetchDescriptor<RewriteRecord>()
        if let records = try? context.fetch(descriptor) {
            for r in records where r.bookID == bid {
                context.delete(r)
            }
        }
        // 清理阅读标注
        let annotationDescriptor = FetchDescriptor<ReadingAnnotation>()
        if let annotations = try? context.fetch(annotationDescriptor) {
            for a in annotations where a.bookID == bid {
                context.delete(a)
            }
        }
        // 下载任务仅通过 UUID 关联，无法依赖 SwiftData 级联删除。
        let downloadDescriptor = FetchDescriptor<DownloadTask>()
        let downloadTasks = ((try? context.fetch(downloadDescriptor)) ?? []).filter { $0.bookID == bid }
        let taskIDs = Set(downloadTasks.map(\.id))
        let itemDescriptor = FetchDescriptor<DownloadTaskItem>()
        if let items = try? context.fetch(itemDescriptor) {
            for item in items where taskIDs.contains(item.taskID) {
                context.delete(item)
            }
        }
        for task in downloadTasks { context.delete(task) }
        context.delete(book)
        try context.save()
        // 向量索引与记忆锚点在 Application Support 下，SwiftData 不会级联删除；
        // 长篇的索引可达数十 MB，不清理会永久残留并被 iCloud 备份。
        BookUnderstandingCoordinator.shared.purge(bookID: bid)
    }

    /// 导出全书为 TXT（含改写后正文）
    @MainActor
    static func exportTXT(book: Book) throws -> URL {
        let chapters = (book.chapters ?? []).sorted { $0.index < $1.index }
        var parts: [String] = []
        parts.append("《\(book.title)》")
        if !book.author.isEmpty {
            parts.append(String(localized: "作者：\(book.author)"))
        }
        parts.append("")
        for ch in chapters {
            parts.append(ch.title)
            parts.append("")
            parts.append(ch.content.replacingOccurrences(
                of: ChapterRichContent.imagePlaceholder,
                with: ""
            ))
            parts.append("")
            parts.append("--------")
            parts.append("")
        }
        let text = parts.joined(separator: "\n")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(exportFilename(for: book.title)).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 书名来自 EPUB 的 dc:title 等文件内容，完全不可信。
    /// 白名单化字符（黑名单挡不住 `..`、NUL、RTL override 等），并追加短 UUID 避免同名覆盖。
    private static func exportFilename(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -_()[]（）【】"))
        var sanitized = String(
            title.unicodeScalars
                .map { allowed.contains($0) || $0.value > 0x2FFF ? Character($0) : "_" }
                .prefix(60)
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // 全为下划线、以点开头，或退化成 "." / ".." 时一律回退到固定名。
        if sanitized.isEmpty
            || sanitized.hasPrefix(".")
            || sanitized.allSatisfy({ $0 == "_" }) {
            sanitized = String(localized: "未命名")
        }
        return "\(sanitized)-\(UUID().uuidString.prefix(8))"
    }

    /// fileImporter 允许的类型（尽量宽，避免选不到文件）
    static var allowedContentTypes: [UTType] {
        let epubType = UTType("org.idpf.epub-container")
            ?? UTType(importedAs: "org.idpf.epub-container", conformingTo: .data)
        var types: [UTType] = [
            epubType,
            .item,
            .data,
            .content,
            .text,
            .plainText,
            .utf8PlainText,
            .utf16PlainText
        ]
        if let epub = UTType(filenameExtension: "epub") {
            types.append(epub)
        }
        if let txt = UTType(filenameExtension: "txt") {
            types.append(txt)
        }
        if let text = UTType(filenameExtension: "text") {
            types.append(text)
        }
        // 去重保持顺序
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }
}
