import AoCKit
import SwiftUI
import WebKit

/// Captures the adventofcode.com `session` cookie from the in-app puzzle browser.
///
/// The browser uses a non-persistent website data store, so whatever you log in with (AoC and the
/// GitHub/Google/Reddit page it sends you to) lives in memory for this run of the app only. The
/// cookie is never written to disk; it is handed to `onSession` and used for downloads.
@MainActor
final class AoCLogin: NSObject, WKHTTPCookieStoreObserver {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    /// Called on the main actor whenever a (new) session cookie shows up.
    var onSession: ((String) -> Void)?

    override init() {
        super.init()
        dataStore.httpCookieStore.add(self)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            let cookies = await cookieStore.allCookies()
            let session = cookies.first { $0.name == "session" && AoCClient.isAoCCookieDomain($0.domain) }
            if let value = session?.value, !value.isEmpty { self.onSession?(value) }
        }
    }
}

/// Sheet with the puzzle page. Log in there and the app downloads every missing input by itself.
struct PuzzleBrowser: View {
    let url: URL
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.hasLoginSession {
                    Label(model.loginStatus ?? "Logged in", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .lineLimit(2)
                } else {
                    Label(
                        "Log in to Advent of Code here and the app downloads all your missing inputs "
                            + "(the cookie stays in memory, never on disk)",
                        systemImage: "person.badge.key")
                }
                Spacer()
                Link("Open in Browser", destination: url)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            PuzzleWebView(url: url, dataStore: model.login.dataStore)
        }
        .frame(width: 1100, height: 780)
    }
}

private struct PuzzleWebView: NSViewRepresentable {
    let url: URL
    let dataStore: WKWebsiteDataStore

    func makeNSView(context _: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Present as Safari: some sign-in providers refuse unknown embedded browsers.
        view.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/26.0 Safari/605.1.15"
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_: WKWebView, context _: Context) {}
}
