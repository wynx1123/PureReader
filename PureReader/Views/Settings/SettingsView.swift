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
                        Label(String(localized: "AI 与语音"), systemImage: "sparkles")
                    }
                    NavigationLink {
                        BackupView()
                    } label: {
                        Label(
                            String(localized: "备份与恢复"),
                            systemImage: "externaldrive.badge.timemachine"
                        )
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
                    LabeledContent(String(localized: "数据"), value: String(localized: "纯本地存储"))
                    // 数据不上传任何服务器，也就意味着重装即丢失。
                    // 这个风险必须讲清楚，否则用户不会主动去备份。
                    Text(String(localized: "书籍与阅读记录只保存在本机，不会上传。重装 App 或更换设备前，请先到「备份与恢复」导出备份。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
