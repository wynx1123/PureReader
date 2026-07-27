import SwiftUI
import SwiftData

struct BookEditSheet: View {
    @Bindable var book: Book
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var author: String = ""
    @State private var group: String = BuiltInGroup.default
    @State private var tagsText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "基本信息")) {
                    TextField(String(localized: "书名"), text: $title)
                    TextField(String(localized: "作者"), text: $author)
                }
                Section(String(localized: "整理")) {
                    Picker(String(localized: "分组"), selection: $group) {
                        ForEach(BuiltInGroup.all, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    TextField(String(localized: "标签（逗号分隔）"), text: $tagsText)
                        .textInputAutocapitalization(.never)
                }
                Section(String(localized: "详情")) {
                    LabeledContent(String(localized: "章节数"), value: "\(book.totalChapters)")
                    LabeledContent(String(localized: "格式"), value: book.format.rawValue.uppercased())
                    LabeledContent(
                        String(localized: "进度"),
                        value: "\(Int(book.progressFraction * 100))%"
                    )
                }
            }
            .navigationTitle(String(localized: "编辑书籍"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存")) {
                        book.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        book.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
                        book.group = group == BuiltInGroup.default ? nil : group
                        book.tags = tagsText
                            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" })
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        try? modelContext.save()
                        dismiss()
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .onAppear {
                title = book.title
                author = book.author
                group = book.groupDisplayName
                tagsText = book.tags.joined(separator: ", ")
            }
        }
    }
}
