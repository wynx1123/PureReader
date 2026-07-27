import Foundation
import SwiftUI
import Observation
import WebKit

@MainActor
@Observable
final class BookSourceVerificationSession {
    @ObservationIgnored weak var webView: WKWebView?
    var isLoading = true

    func reload() {
        webView?.reload()
    }

    func cookieHeader(for url: URL) async -> String {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { values in
                continuation.resume(returning: values)
            }
        }
        guard let host = url.host?.lowercased() else { return "" }
        return cookies
            .filter { cookie in
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                return host == domain || host.hasSuffix("." + domain)
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}

struct BookSourceVerificationView: View {
    let request: BookSourceVerificationRequest
    let headerJSON: String
    let onComplete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var session = BookSourceVerificationSession()
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                VerificationWebView(
                    url: request.url,
                    headerJSON: headerJSON,
                    session: session
                )
                if session.isLoading {
                    ProgressView()
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
            .navigationTitle(request.sourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button {
                        session.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(String(localized: "刷新验证页面"))

                    Button(String(localized: "验证完成")) {
                        Task {
                            let cookie = await session.cookieHeader(for: request.url)
                            guard !cookie.isEmpty else {
                                message = String(localized: "还没有读取到验证 Cookie。请先在网页中完成人机验证，再点“验证完成”。")
                                return
                            }
                            onComplete(cookie)
                            dismiss()
                        }
                    }
                }
            }
            .alert(
                String(localized: "提示"),
                isPresented: Binding(
                    get: { message != nil },
                    set: { if !$0 { message = nil } }
                )
            ) {
                Button(String(localized: "好"), role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }
}

private struct VerificationWebView: UIViewRepresentable {
    let url: URL
    let headerJSON: String
    let session: BookSourceVerificationSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        session.webView = webView

        var request = URLRequest(url: url)
        for (key, value) in parsedHeaders() where key.caseInsensitiveCompare("Cookie") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: key)
        }
        webView.load(request)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private func parsedHeaders() -> [String: String] {
        guard let data = headerJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var headers: [String: String] = [:]
        for (key, value) in object {
            if let text = value as? String { headers[key] = text }
        }
        return headers
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let session: BookSourceVerificationSession

        init(session: BookSourceVerificationSession) {
            self.session = session
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            Task { @MainActor in session.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            Task { @MainActor in session.isLoading = false }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            Task { @MainActor in session.isLoading = false }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            Task { @MainActor in session.isLoading = false }
        }
    }
}


