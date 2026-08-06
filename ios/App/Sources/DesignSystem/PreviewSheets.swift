import SwiftUI
import WebKit
import MarkdownUI

/// Full-screen rendered markdown preview.
struct MarkdownPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let markdown: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Markdown(markdown)
                    .markdownTheme(.anyProv(fontSize: 17))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Markdown preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}

/// In-app browser for HTML snippets or files.
struct HTMLPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let html: String
    var title: String = "Preview"
    var baseURL: URL? = nil

    var body: some View {
        NavigationStack {
            HTMLWebView(html: html, baseURL: baseURL)
                .background(Theme.background)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}

private struct HTMLWebView: UIViewRepresentable {
    let html: String
    var baseURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Theme.background)
        webView.scrollView.backgroundColor = UIColor(Theme.background)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Avoid reloading identical content on every SwiftUI pass.
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            let wrapped = Self.wrapIfNeeded(html)
            webView.loadHTMLString(wrapped, baseURL: baseURL)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String?
    }

    /// Inject a dark-friendly body style when the document has no full HTML shell.
    private static func wrapIfNeeded(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype") {
            return raw
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <style>
            :root { color-scheme: dark; }
            body {
              margin: 16px;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              background: #0B0D10;
              color: #E8ECF1;
              line-height: 1.45;
            }
            a { color: #6AA9FF; }
            pre, code {
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
              background: #14181D;
              border-radius: 6px;
            }
            pre { padding: 12px; overflow-x: auto; }
            code { padding: 1px 4px; }
          </style>
        </head>
        <body>
        \(raw)
        </body>
        </html>
        """
    }
}
