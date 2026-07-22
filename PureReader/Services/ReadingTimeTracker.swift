import Foundation
import SwiftData
import Observation

/// 阅读计时：秒级累计，每 10 秒写入 SwiftData
@MainActor
@Observable
final class ReadingTimeTracker {
    private(set) var sessionSeconds: Int = 0
    private var isActive = false
    private var ticker: Task<Void, Never>?
    private var sinceLastFlush = 0

    private weak var book: Book?
    private var modelContext: ModelContext?

    func attach(book: Book, context: ModelContext) {
        self.book = book
        self.modelContext = context
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard self.isActive else { return }
                    self.sessionSeconds += 1
                    self.sinceLastFlush += 1
                    if self.sinceLastFlush >= 10 {
                        self.flush(force: false)
                    }
                }
            }
        }
    }

    func pause() {
        isActive = false
        flush(force: true)
        ticker?.cancel()
        ticker = nil
    }

    func stop() {
        isActive = false
        flush(force: true)
        ticker?.cancel()
        ticker = nil
        sessionSeconds = 0
        sinceLastFlush = 0
    }

    private func flush(force: Bool) {
        guard let book, let context = modelContext else { return }
        let delta = sinceLastFlush
        guard delta > 0 || force else { return }
        if delta <= 0 { return }

        book.totalReadingSeconds += delta

        // 写入/合并当日 ReadingRecord
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let records = book.records ?? []
        if let existing = records.first(where: { calendar.isDate($0.date, inSameDayAs: startOfDay) }) {
            existing.durationSeconds += delta
        } else {
            let record = ReadingRecord(date: startOfDay, durationSeconds: delta)
            record.book = book
            context.insert(record)
            if book.records == nil {
                book.records = [record]
            } else {
                book.records?.append(record)
            }
        }

        sinceLastFlush = 0
        try? context.save()
    }
}
