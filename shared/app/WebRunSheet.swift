// "Run on the web": the page a host serves the last build at (the iPhone's
// and the Mac's WebRunServer, Android's), in the Isomer module's web view
// (WKWebView on Apple platforms, android.webkit.WebView on Android), the
// same sheet everywhere a host serves one. The page runs the build with the
// platform's own WebAssembly engine and draws it with the DOM renderer.

import Isomer
import SwiftUI

struct WebRunSheet: View {
    let url: URL?
    /// The project's name, the sheet's title.
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // Isomer's, by name: WebKit has a SwiftUI WebView of its own
            // where both are imported.
            Isomer.WebView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("web-run")
                // Where the page comes from: the app's own server, on this
                // device alone.
                .safeAreaInset(edge: .bottom) {
                    if let url {
                        Text("\(url.host ?? ""):\(url.port.map(String.init) ?? "")")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    }
                }
                .navigationTitle(title)
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("web-run-done")
                    }
                }
        }
        // The Mac sizes a sheet to its content, and a web view has none.
        .windowSheetFrame(minWidth: 1000, minHeight: 720)
    }
}
