import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        BookSourceManagerView()
                    } label: {
                        Label(String(localized: "书源管理"), systemImage: "books.vertical")
                    }
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        Label(String(localized: "AI 改写与向量"), systemImage: "sparkles")
                    }
                } header: {
                    Text(String(localized: "功能"))
                }

                Section(String(localized: "关于")) {
                    LabeledContent(String(localized: "应用"), value: String(localized: "纯享阅读"))
                    LabeledContent(
                        String(localized: "版本"),
                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    )
                    LabeledContent(String(localized: "数据"), value: String(localized: "纯本地 SwiftData"))
                    Text(String(localized: "导入 TXT / EPUB / 链接 / 书源，支持听书与 AI 改写。界面风格参考 Apple 图书。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "设置"))
        }
    }
}

#Preview {
    SettingsView()
}
