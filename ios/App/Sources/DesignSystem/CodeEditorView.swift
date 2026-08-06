import SwiftUI
import UIKit
import Highlightr

/// Full-file text editor with syntax highlighting via Highlightr (highlight.js).
struct CodeEditorView: View {
    @Binding var text: String
    var language: String?
    var isEditable: Bool = true
    var onEditingChanged: ((Bool) -> Void)? = nil

    var body: some View {
        HighlightingTextView(
            text: $text,
            language: language,
            isEditable: isEditable,
            onEditingChanged: onEditingChanged
        )
        .background(Theme.field)
    }
}

// MARK: - Language detection

enum CodeLanguage {
    /// Map a file path / extension to a highlight.js language id.
    static func detect(from path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "ts", "tsx", "mts", "cts": return "typescript"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "md", "mdx", "markdown": return "markdown"
        case "html", "htm", "xhtml": return "xml"
        case "css", "scss", "sass", "less": return "css"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java", "kt", "kts": return "java"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh": return "cpp"
        case "m", "mm": return "objectivec"
        case "sh", "bash", "zsh": return "bash"
        case "sql": return "sql"
        case "xml", "plist": return "xml"
        case "toml": return "ini"
        case "dockerfile": return "dockerfile"
        case "graphql", "gql": return "graphql"
        case "proto": return "protobuf"
        case "r": return "r"
        case "php": return "php"
        case "cs": return "csharp"
        case "diff", "patch": return "diff"
        default:
            let name = (path as NSString).lastPathComponent.lowercased()
            if name == "dockerfile" { return "dockerfile" }
            if name == "makefile" || name.hasPrefix("makefile.") { return "makefile" }
            if name == "package.json" || name.hasSuffix(".json") { return "json" }
            return nil
        }
    }

    static func isMarkdown(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["md", "mdx", "markdown"].contains(ext)
    }

    static func isHTML(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["html", "htm", "xhtml"].contains(ext)
    }
}

// MARK: - UITextView bridge

private struct HighlightingTextView: UIViewRepresentable {
    @Binding var text: String
    var language: String?
    var isEditable: Bool
    var onEditingChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let highlightr = Highlightr()
        highlightr?.setTheme(to: "atom-one-dark")
        context.coordinator.highlightr = highlightr

        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = UIColor(Theme.field)
        tv.textColor = UIColor(Theme.textPrimary)
        tv.tintColor = UIColor(Theme.accent)
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        tv.isEditable = isEditable
        tv.isSelectable = true
        tv.allowsEditingTextAttributes = false

        context.coordinator.applyHighlight(to: tv, text: text, force: true)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.isEditable = isEditable
        context.coordinator.parent = self
        // Only push external text changes (load / reset) — not our own edits.
        if !context.coordinator.isEditing && uiView.text != text {
            context.coordinator.applyHighlight(to: uiView, text: text, force: true)
        } else if context.coordinator.language != language {
            context.coordinator.language = language
            context.coordinator.applyHighlight(to: uiView, text: uiView.text ?? "", force: true)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HighlightingTextView
        var highlightr: Highlightr?
        var language: String?
        var isEditing = false
        private var highlightWorkItem: DispatchWorkItem?

        init(_ parent: HighlightingTextView) {
            self.parent = parent
            self.language = parent.language
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
            parent.onEditingChanged?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            parent.onEditingChanged?(false)
            applyHighlight(to: textView, text: textView.text ?? "", force: true)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            scheduleHighlight(textView)
        }

        private func scheduleHighlight(_ textView: UITextView) {
            highlightWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyHighlight(to: textView, text: textView.text ?? "", force: false)
            }
            highlightWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
        }

        func applyHighlight(to textView: UITextView, text: String, force: Bool) {
            let selected = textView.selectedRange
            let offset = textView.contentOffset

            guard let highlightr else {
                if textView.text != text {
                    textView.text = text
                }
                return
            }

            let highlighted: NSAttributedString
            if let language = language ?? parent.language,
               let attr = highlightr.highlight(text, as: language) {
                highlighted = attr
            } else if let attr = highlightr.highlight(text) {
                highlighted = attr
            } else {
                highlighted = NSAttributedString(
                    string: text,
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                        .foregroundColor: UIColor(Theme.textPrimary),
                    ]
                )
            }

            // Preserve selection while swapping attributed text.
            let mutable = NSMutableAttributedString(attributedString: highlighted)
            // Ensure a readable base font size even if theme omits it.
            mutable.addAttribute(
                .font,
                value: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                range: NSRange(location: 0, length: mutable.length)
            )

            if force || textView.attributedText?.string != text {
                textView.attributedText = mutable
                let maxLoc = (textView.text as NSString?)?.length ?? 0
                let loc = min(selected.location, maxLoc)
                let len = min(selected.length, max(0, maxLoc - loc))
                textView.selectedRange = NSRange(location: loc, length: len)
                textView.setContentOffset(offset, animated: false)
            }
        }
    }
}
