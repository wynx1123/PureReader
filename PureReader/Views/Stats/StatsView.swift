import SwiftUI
import SwiftData

struct StatsView: View {
    @Query(sort: \Book.lastReadAt, order: .reverse) private var books: [Book]
    @Query(sort: \ReadingRecord.date, order: .reverse) private var records: [ReadingRecord]

    private var totalSeconds: Int {
        books.reduce(0) { $0 + $1.totalReadingSeconds }
    }

    private var todaySeconds: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return records
            .filter { Calendar.current.isDate($0.date, inSameDayAs: start) }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summaryCards
                    heatmapSection
                    bookListSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(String(localized: "统计"))
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            statCard(
                title: String(localized: "今日"),
                value: formatDuration(todaySeconds),
                systemImage: "sun.max.fill"
            )
            statCard(
                title: String(localized: "累计"),
                value: formatDuration(totalSeconds),
                systemImage: "clock.fill"
            )
            statCard(
                title: String(localized: "书籍"),
                value: "\(books.count)",
                systemImage: "books.vertical.fill"
            )
        }
    }

    private func statCard(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "近 12 周阅读热力"))
                .font(.headline)

            ReadingHeatmap(records: records)
                .frame(height: 96)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var bookListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "阅读时长排行"))
                .font(.headline)

            if books.isEmpty {
                Text(String(localized: "开始阅读后，这里会显示你的统计"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(books.sorted(by: { $0.totalReadingSeconds > $1.totalReadingSeconds }).prefix(20), id: \.persistentModelID) { book in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(book.author.isEmpty ? String(localized: "未知作者") : book.author)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatDuration(book.totalReadingSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 {
            return String(localized: "\(h) 小时 \(m) 分")
        }
        if m > 0 {
            return String(localized: "\(m) 分钟")
        }
        return String(localized: "\(seconds) 秒")
    }
}

// MARK: - Heatmap

struct ReadingHeatmap: View {
    let records: [ReadingRecord]

    private var dayMap: [Date: Int] {
        var map: [Date: Int] = [:]
        let cal = Calendar.current
        for r in records {
            let d = cal.startOfDay(for: r.date)
            map[d, default: 0] += r.durationSeconds
        }
        return map
    }

    private var days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // 12 周 = 84 天
        return (0..<84).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 12)
        // 按周列：简化为 12 列 × 7 行
        let grid = stride(from: 0, to: 84, by: 1).map { offset -> Date in
            days[offset]
        }

        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(Array(grid.enumerated()), id: \.offset) { _, date in
                let seconds = dayMap[date] ?? 0
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color(for: seconds))
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel(Text("\(date.formatted(date: .abbreviated, time: .omitted)): \(seconds)s"))
            }
        }
    }

    private func color(for seconds: Int) -> Color {
        if seconds <= 0 { return Color.secondary.opacity(0.12) }
        if seconds < 600 { return Color.green.opacity(0.25) }
        if seconds < 1800 { return Color.green.opacity(0.45) }
        if seconds < 3600 { return Color.green.opacity(0.65) }
        return Color.green.opacity(0.9)
    }
}

#Preview {
    StatsView()
        .modelContainer(for: [Book.self, ReadingRecord.self], inMemory: true)
}
