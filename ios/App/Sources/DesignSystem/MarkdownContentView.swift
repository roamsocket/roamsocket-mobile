import SwiftUI
import MarkdownUI

/// Renders assistant message bodies as Markdown (GFM).
///
/// Fenced blocks tagged as `markdown` / `md` / `mdx` stay as raw source with a
/// Preview button. Fenced `html` / `htm` blocks stay raw with a browser Preview.
struct MarkdownContentView: View {
    let text: String
    var fontSize: CGFloat = 17

    private var segments: [MessageSegment] {
        MessageSegmentParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(segments) { segment in
                switch segment {
                case let .markdown(body):
                    if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Markdown(body)
                            .markdownTheme(.anyProv(fontSize: fontSize))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .snippet(kind, language, code):
                    SnippetBlock(kind: kind, language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Theme

extension MarkdownUI.Theme {
    /// Cool blue-grey theme aligned with `Theme` tokens.
    static func anyProv(fontSize: CGFloat) -> MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                ForegroundColor(Theme.textPrimary)
                FontSize(fontSize)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                ForegroundColor(Theme.codeToken)
                BackgroundColor(Theme.surfaceElevated)
            }
            .link {
                ForegroundColor(Theme.accent)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(fontSize * 1.35)
                        ForegroundColor(Theme.textPrimary)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(fontSize * 1.2)
                        ForegroundColor(Theme.textPrimary)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(fontSize * 1.08)
                        ForegroundColor(Theme.textPrimary)
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.15))
                    .markdownMargin(top: 0, bottom: 8)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .relativeLineSpacing(.em(0.12))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.85))
                            ForegroundColor(Theme.textPrimary)
                        }
                        .padding(12)
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .markdownMargin(top: 6, bottom: 10)
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(Theme.textSecondary)
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.accent.opacity(0.55))
                            .frame(width: 3)
                    }
                    .markdownMargin(top: 4, bottom: 8)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.15))
            }
            .table { configuration in
                configuration.label
                    .markdownMargin(top: 6, bottom: 10)
            }
            .thematicBreak {
                Divider()
                    .overlay(Theme.separator)
                    .markdownMargin(top: 8, bottom: 8)
            }
    }
}

// MARK: - Segments

enum MessageSegment: Identifiable, Equatable {
    case markdown(String)
    case snippet(kind: SnippetKind, language: String, code: String)

    var id: String {
        switch self {
        case let .markdown(s): return "m-\(s.hashValue)"
        case let .snippet(kind, language, code): return "s-\(kind.rawValue)-\(language)-\(code.hashValue)"
        }
    }
}

enum SnippetKind: String, Equatable {
    case markdown
    case html
}

enum MessageSegmentParser {
    private static let fencePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"```([^\n`]*)\n([\s\S]*?)```"#,
            options: []
        )
    }()

    static func parse(_ raw: String) -> [MessageSegment] {
        guard !raw.isEmpty else { return [] }
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = fencePattern.matches(in: raw, options: [], range: full)

        var segments: [MessageSegment] = []
        var cursor = 0

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let whole = match.range(at: 0)
            let langRange = match.range(at: 1)
            let bodyRange = match.range(at: 2)

            if whole.location > cursor {
                let prose = ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
                if !prose.isEmpty {
                    segments.append(.markdown(prose))
                }
            }

            let lang = ns.substring(with: langRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let code = ns.substring(with: bodyRange)
            // Drop a single trailing newline common after fence open.
            let trimmedCode = code.hasSuffix("\n") ? String(code.dropLast()) : code

            if let kind = snippetKind(for: lang) {
                segments.append(.snippet(kind: kind, language: lang.isEmpty ? kind.rawValue : lang, code: trimmedCode))
            } else {
                // Keep ordinary fences in Markdown so MarkdownUI styles them.
                let fence = ns.substring(with: whole)
                segments.append(.markdown(fence))
            }

            cursor = whole.location + whole.length
        }

        if cursor < ns.length {
            let tail = ns.substring(from: cursor)
            if !tail.isEmpty {
                segments.append(.markdown(tail))
            }
        }

        if segments.isEmpty {
            return [.markdown(raw)]
        }
        return segments
    }

    private static func snippetKind(for language: String) -> SnippetKind? {
        switch language {
        case "markdown", "md", "mdx", "gfm":
            return .markdown
        case "html", "htm", "xhtml":
            return .html
        default:
            return nil
        }
    }
}

// MARK: - Snippet block (raw + preview)

private struct SnippetBlock: View {
    let kind: SnippetKind
    let language: String
    let code: String

    @State private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(languageLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Button {
                    showPreview = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: kind == .html ? "safari" : "eye")
                            .font(.system(size: 12, weight: .semibold))
                        Text(kind == .html ? "Preview in browser" : "Preview")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surfaceElevated)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Theme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.6), lineWidth: 1)
        )
        .sheet(isPresented: $showPreview) {
            Group {
                switch kind {
                case .markdown:
                    MarkdownPreviewSheet(markdown: code)
                case .html:
                    HTMLPreviewSheet(html: code, title: "HTML preview")
                }
            }
        }
    }

    private var languageLabel: String {
        language.isEmpty ? kind.rawValue : language
    }
}
