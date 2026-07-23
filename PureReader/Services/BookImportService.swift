import Foundation
import SwiftData
import UniformTypeIdentifiers

/// 无状态导入服务：安全作用域 → 沙盒副本 → 解析 → SwiftData
enum BookImportService {
    static let maxFileBytes = 50 * 1024 * 1024

    // MARK: - Public parse

    /// 从 fileImporter / 分享扩展等安全作用域 URL 导入。
    /// 独立调用时由本方法取得 scope；标准 UI 流程会在 completion 取得 scope，
    /// 再通过后台协调读取完成暂存。
    static func parseLocalFile(url: URL) async throws -> ParsedBook {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let sandboxURL = try await stageSecurityScopedFileAsync(url)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        return try await parseStagedFile(
            url: sandboxURL,
            originalFilename: url.lastPathComponent
        )
    }

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
            forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        ) {
            if sourceValues.isDirectory == true || sourceValues.isRegularFile == false {
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
                try fm.copyItem(at: readableURL, to: destination)
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

    // MARK: - Security-scoped copy

    /// 将 fileImporter 返回的 URL 复制到 Caches/Imports，避免权限丢失。
    /// `acquireSecurityScope` 仅供非 fileImporter 调用；标准流程必须在 completion 当下获取 scope。
    static func copyToSandbox(_ url: URL, acquireSecurityScope: Bool = true) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let accessed = acquireSecurityScope ? url.startAccessingSecurityScopedResource() : false
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            let fm = FileManager.default
            let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Imports", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            var name = url.lastPathComponent
            if name.isEmpty { name = "import.bin" }
            // 保留扩展名
            let dest = dir.appendingPathComponent("\(UUID().uuidString)_\(name)")

            // 若协调器需要
            var coordError: NSError?
            var copyError: Error?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { newURL in
                do {
                    if fm.fileExists(atPath: dest.path) {
                        try fm.removeItem(at: dest)
                    }
                    try fm.copyItem(at: newURL, to: dest)
                } catch {
                    copyError = error
                }
            }
            if let coordError { throw ImportError.accessDenied(coordError.localizedDescription) }
            if let copyError {
                // 回退直接 Data 读写
                do {
                    let data = try Data(contentsOf: url)
                    if data.isEmpty { throw ImportError.emptyFile }
                    try data.write(to: dest, options: .atomic)
                } catch let e as ImportError {
                    throw e
                } catch {
                    throw ImportError.accessDenied(copyError.localizedDescription)
                }
            }
            guard fm.fileExists(atPath: dest.path) else {
                throw ImportError.accessDenied(String(localized: "无法访问所选文件"))
            }
            return dest
        }.value
    }

    private static func downloadWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await URLSession.shared.data(for: request)
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
                content: pc.content.isEmpty ? " " : pc.content
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

        updateKnownTags(tags, context: context)
        return book
    }

    @MainActor
    private static func updateKnownTags(_ tags: [String], context: ModelContext) {
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
        try? context.save()
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
        context.delete(book)
        try context.save()
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
            parts.append(ch.content)
            parts.append("")
            parts.append("--------")
            parts.append("")
        }
        let text = parts.joined(separator: "\n")
        let dir = FileManager.default.temporaryDirectory
        let safe = book.title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let url = dir.appendingPathComponent("\(safe).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// fileImporter 允许的类型（尽量宽，避免选不到文件）
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [
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
