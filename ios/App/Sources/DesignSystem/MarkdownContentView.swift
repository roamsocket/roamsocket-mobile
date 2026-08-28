import SwiftUI
import UIKit
import MarkdownUI
import Highlightr

/// Renders assistant message bodies as Markdown (GFM).
///
/// Fenced blocks tagged as `markdown` / `md` / `mdx` stay as raw source with a
/// Preview button. Fenced `html` / `htm` blocks stay raw with a browser Preview.
/// Any other fenced code block (e.g. ```` ```python ````) is lifted out of
/// the markdown and rendered as its own code card with a header (language
/// label + Copy button) and a Highlightr-highlighted body. Auto-detects the
/// language from the fence info string (`ts` → `typescript`, `py` → `python`,
/// etc.) and falls back to plain monospaced text when Highlightr does not
/// know the language.
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
                    CodeBlockView(
                        language: language,
                        code: code,
                        kind: .snippet(kind)
                    )
                case let .codeBlock(language, code):
                    CodeBlockView(
                        language: language,
                        code: code,
                        kind: .code
                    )
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
    /// Fenced `markdown` / `html` block: keep raw, show Preview.
    case snippet(kind: SnippetKind, language: String, code: String)
    /// Any other fenced code block: header + Copy + Highlightr body.
    case codeBlock(language: String, code: String)

    /// Stable, position-derived id. `String.hashValue` collides on long
    /// messages and breaks `ForEach` diffing when the same code appears twice.
    var id: String {
        switch self {
        case .markdown: return "markdown"
        case let .snippet(_, language, code): return "snippet-\(language)-\(code.count)-\(code.hashValue)"
        case let .codeBlock(language, code): return "code-\(language)-\(code.count)-\(code.hashValue)"
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
                // Lift all other fenced blocks into a code block with header +
                // Copy + Highlightr highlighting. Use the info string verbatim
                // when present, otherwise let the language detector sniff.
                let label = lang.isEmpty
                    ? CodeLanguage.detectLanguage(in: trimmedCode) ?? "text"
                    : CodeLanguage.normalize(lang) ?? lang
                segments.append(.codeBlock(language: label, code: trimmedCode))
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

// MARK: - Code block view (snippet / generic)

private struct CodeBlockView: View {
    let language: String
    let code: String
    /// `.snippet` shows the Preview capsule (markdown → `MarkdownPreviewSheet`,
    /// html → `HTMLPreviewSheet`); `.code` shows a Copy-only header.
    let kind: Kind

    enum Kind: Equatable {
        case snippet(SnippetKind)
        case code
    }

    @State private var showPreview = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            codeBody
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.6), lineWidth: 1)
        )
        .sheet(isPresented: $showPreview) {
            previewSheet
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(displayLanguage)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .lineLimit(1)
            Spacer(minLength: 0)
            CopyButton(text: code, didCopy: $didCopy)
            if case let .snippet(snippetKind) = kind {
                Button {
                    showPreview = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: snippetKind == .html ? "safari" : "eye")
                            .font(.system(size: 12, weight: .semibold))
                        Text(snippetKind == .html ? "Preview in browser" : "Preview")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceElevated)
    }

    private var displayLanguage: String {
        if language.isEmpty {
            if case let .snippet(kind) = self.kind { return kind.rawValue }
            return "text"
        }
        return language
    }

    // MARK: Body

    @ViewBuilder
    private var codeBody: some View {
        if kind == .code {
            HighlightedCodeView(text: code, language: language)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    // MARK: Preview sheet (snippet only)

    @ViewBuilder
    private var previewSheet: some View {
        if case let .snippet(snippetKind) = kind {
            switch snippetKind {
            case .markdown: MarkdownPreviewSheet(markdown: code)
            case .html: HTMLPreviewSheet(html: code, title: "HTML preview")
            }
        }
    }
}

// MARK: - Copy button

private struct CopyButton: View {
    let text: String
    @Binding var didCopy: Bool

    var body: some View {
        Button {
            copy()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                Text(didCopy ? "Copied" : "Copy")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(didCopy ? Theme.selection : Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                (didCopy ? Theme.selection : Theme.accent).opacity(0.14),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "Copied" : "Copy code")
    }

    private func copy() {
        let trimmed = text.isEmpty ? " " : text
        UIPasteboard.general.string = trimmed
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }
}

// MARK: - Highlightr-backed code body

/// Read-only, Highlightr-highlighted `UITextView` bridge. Uses highlight.js
/// (bundled inside Highlightr) and the active `Theme` for color tokens.
struct HighlightedCodeView: UIViewRepresentable {
    let text: String
    let language: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.alwaysBounceVertical = false
        tv.alwaysBounceHorizontal = true
        tv.showsHorizontalScrollIndicator = true
        tv.showsVerticalScrollIndicator = false
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        tv.textContainer.lineFragmentPadding = 0
        tv.backgroundColor = UIColor(Theme.surface)
        tv.tintColor = UIColor(Theme.accent)
        tv.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        context.coordinator.apply(to: tv, text: text, language: language)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.apply(to: uiView, text: text, language: language)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        // Single shared Highlightr instance is safe — it's stateless per call
        // aside from the active theme, which we set on every apply().
        private static let sharedHighlightr: Highlightr? = Highlightr()

        private var lastText: String = ""
        private var lastLanguage: String = ""
        private var lastLightTheme: Bool = Theme.isLight

        func apply(to tv: UITextView, text: String, language: String) {
            let display = text.isEmpty ? " " : text
            let light = Theme.isLight
            // Re-highlight when content, language, or theme changes.
            if display == lastText,
               language == lastLanguage,
               light == lastLightTheme,
               tv.attributedText.length > 0 {
                return
            }
            lastText = display
            lastLanguage = language
            lastLightTheme = light

            guard let highlightr = Self.sharedHighlightr else {
                tv.text = display
                tv.textColor = UIColor(Theme.textPrimary)
                return
            }
            highlightr.setTheme(to: light ? "atom-one-light" : "atom-one-dark")
            let themeBackground = (highlightr.theme?.themeBackgroundColor)
                .map { UIColor(cgColor: $0.cgColor) }
                ?? UIColor(Theme.surface)
            tv.backgroundColor = themeBackground

            // Try requested language first, then a few common aliases, then
            // fall back to auto-detection, then to plain monospaced text.
            let candidates = CodeLanguage.highlightCandidates(for: language)
            var attributed: NSAttributedString?
            for candidate in candidates {
                if let attr = highlightr.highlight(display, as: candidate, fastRender: true) {
                    attributed = attr
                    break
                }
            }
            if attributed == nil {
                attributed = highlightr.highlight(display, fastRender: true)
            }
            guard let attributed else {
                tv.text = display
                tv.textColor = UIColor(Theme.textPrimary)
                return
            }
            // The highlight.js theme supplies its own colors; force the base
            // font so it stays consistent with our snippet monospace size.
            let mutable = NSMutableAttributedString(attributedString: attributed)
            let fullRange = NSRange(location: 0, length: mutable.length)
            mutable.addAttribute(.font,
                                 value: UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                                 range: fullRange)
            tv.attributedText = mutable
        }
    }
}

// MARK: - Language helpers

extension CodeLanguage {
    /// Normalize a fence info string to a highlight.js language id. Returns
    /// nil if the string is not a known alias and Highlightr should try
    /// auto-detection.
    static func normalize(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return nil }
        return aliases[key]
    }

    /// Ordered list of highlight.js language ids to try when highlighting
    /// `text`. Always includes the raw label first, then any aliases, then
    /// `nil` (Highlightr auto-detect) as a last resort.
    static func highlightCandidates(for label: String) -> [String] {
        var candidates: [String] = []
        let key = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.isEmpty { candidates.append(key) }
        if let resolved = aliases[key], !candidates.contains(resolved) {
            candidates.append(resolved)
        }
        return candidates
    }

    /// Heuristic auto-detect: scan the first non-empty lines for a known
    /// shebang / comment style and return a highlight.js id, otherwise nil.
    /// Renamed from `detect(from:)` to avoid colliding with the path-based
    /// `CodeLanguage.detect(from path: String)` in `CodeEditorView.swift`.
    static func detectLanguage(in code: String) -> String? {
        let head = code.split(separator: "\n", maxSplits: 4, omittingEmptySubsequences: true)
        for line in head {
            let lower = line.lowercased()
            if lower.hasPrefix("#!") {
                if lower.contains("python") { return "python" }
                if lower.contains("ruby") { return "ruby" }
                if lower.contains("bash") || lower.contains("/sh") { return "bash" }
                if lower.contains("node") { return "javascript" }
                if lower.contains("deno") { return "typescript" }
            }
            if lower.hasPrefix("<?php") { return "php" }
            if lower.hasPrefix("package ") && lower.contains(";") { return "go" }
            if lower.hasPrefix("import ") && lower.contains("\"") && !lower.contains("from ") {
                return "go"
            }
        }
        return nil
    }

    private static let aliases: [String: String] = [
        // Common file-extension aliases mapped to highlight.js ids.
        "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "py": "python", "python": "python",
        "rb": "ruby", "ruby": "ruby",
        "kt": "kotlin", "kts": "kotlin", "kotlin": "kotlin",
        "sh": "bash", "bash": "bash", "zsh": "bash", "shell": "bash", "console": "bash",
        "yml": "yaml", "yaml": "yaml",
        "cs": "csharp", "csharp": "csharp",
        "objc": "objectivec", "objectivec": "objectivec",
        "cpp": "cpp", "c++": "cpp", "cxx": "cpp", "hpp": "cpp", "hxx": "cpp",
        "c": "c", "h": "c",
        "md": "markdown", "mdx": "markdown", "gfm": "markdown", "markdown": "markdown",
        "json": "json", "json5": "json",
        "vue": "xml", "svelte": "xml",
        "dockerfile": "dockerfile", "docker": "dockerfile",
        "r": "r", "rs": "rust", "rust": "rust",
        "pl": "perl", "perl": "perl",
        "ex": "elixir", "exs": "elixir", "elixir": "elixir",
        "lua": "lua",
        "dart": "dart",
        "scala": "scala", "sc": "scala",
        "hs": "haskell", "haskell": "haskell",
        "makefile": "makefile", "mk": "makefile", "make": "makefile",
        "diff": "diff", "patch": "diff",
        "sql": "sql",
        "graphql": "graphql", "gql": "graphql",
        "proto": "protobuf", "protobuf": "protobuf",
        "php": "php",
        "ini": "ini", "toml": "ini", "cfg": "ini",
        "log": "plaintext", "txt": "plaintext", "text": "plaintext", "plain": "plaintext",
        "xml": "xml", "plist": "xml", "html": "xml", "htm": "xml", "xhtml": "xml",
    ]
}
