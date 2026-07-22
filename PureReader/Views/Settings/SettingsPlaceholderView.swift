import SwiftUI

struct SettingsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "关于")) {
                    LabeledContent(String(localized: "应用"), value: String(localized: "纯享阅读"))
                    LabeledContent(String(localized: "版本"), value: appVersion)
                    LabeledContent(String(localized: "数据"), value: String(localized: "仅本地存储"))
                }

                Section(String(localized: "承诺")) {
                    Label(String(localized: "零广告"), systemImage: "nosign")
                    Label(String(localized: "零付费墙"), systemImage: "lock.open")
                    Label(String(localized: "数据不上云第三方"), systemImage: "iphone")
                }
            }
            .navigationTitle(String(localized: "设置"))
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsPlaceholderView()
}
