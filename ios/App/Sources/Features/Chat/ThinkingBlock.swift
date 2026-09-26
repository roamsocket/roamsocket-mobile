import SwiftUI
import UIKit

/// Claude-style thinking row: clock on the left, grey summary, chevron on the right.
/// No card/bubble. Tap **expands the row inline** to reveal the full reasoning
/// underneath; tap again to collapse. (The old sheet-based path is gone — the
/// inline disclosure keeps the user in the same scroll position.)
///
/// When `text` is empty (open tag with no body yet), shows a non-interactive
/// grey **Thinking...** row so raw markup never leaks.
struct ThinkingBlock: View {
    /// Full reasoning body.
    let text: String
    /// Optional precomputed one-line label (from Apple Foundation Models).
    var summary: String? = nil
    /// When true, skip the collapse and render the full reasoning inline by
    /// default (Settings → Always expand thinking). The user can still
    /// collapse manually via the chevron.
    var expanded: Bool = false

    @State private var resolvedSummary: String = ""
    @State private var isSummarizing = false
    @State private var showCopiedToast = false
    /// User-controlled disclosure. Seeded from `expanded` so the Settings
    /// "always expand" flag wins, but the user can override per row.
    @State private var isExpanded: Bool

    init(text: String, summary: String? = nil, expanded: Bool = false) {
        self.text = text
        self.summary = summary
        self.expanded = expanded
        self._isExpanded = State(initialValue: expanded)
    }

    private var hasBody: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displaySummary: String {
        if !hasBody { return "Thinking..." }
        if !resolvedSummary.isEmpty { return resolvedSummary }
        if let summary, !summary.isEmpty { return summary }
        return ThinkingSummaryGenerator.heuristicSummary(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryRow

            if hasBody, isExpanded {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                    .padding(.leading, 24) // align under the summary, past the clock icon
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isExpanded)
        .task(id: summaryTaskID) {
            await refreshSummaryIfNeeded()
        }
    }

    // MARK: - Row

    private var summaryRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16, height: 16)

            if hasBody {
                Text(displaySummary)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Empty open `<think>` tag: live typing wave instead of static "Thinking..."
                AssistantTypingIndicator()
            }

            if showCopiedToast {
                Text("Copied")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .transition(.opacity)
            } else if hasBody {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary.opacity(0.75))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasBody else { return }
            isExpanded.toggle()
        }
        .onLongPressGesture(minimumDuration: 0.4, perform: copyThinking)
        .contextMenu {
            if hasBody {
                Button {
                    isExpanded = true
                } label: {
                    Label("Expand", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                Button {
                    isExpanded = false
                } label: {
                    Label("Collapse", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Divider()
                Button {
                    copyThinking()
                } label: {
                    Label("Copy thinking", systemImage: "doc.on.doc")
                }
            }
        }
        .accessibilityAddTraits(hasBody ? .isButton : [])
        .accessibilityLabel(hasBody ? "Thought process: \(displaySummary)" : "Thinking")
        .accessibilityHint(hasBody ? (isExpanded ? "Tap to collapse" : "Tap to expand") : "Model is reasoning")
        .accessibilityAction(named: "Copy thinking") { copyThinking() }
    }

    private var summaryTaskID: String {
        "\(text.hashValue)-\(summary ?? "")"
    }

    // MARK: - Summary

    private func refreshSummaryIfNeeded() async {
        // Prefer a parent-provided label (chat persists on-device summaries).
        if let summary, !summary.isEmpty {
            resolvedSummary = summary
            return
        }
        guard hasBody else {
            resolvedSummary = "Thinking..."
            return
        }
        // Instant heuristic, then refine with on-device model when available.
        if resolvedSummary.isEmpty {
            resolvedSummary = ThinkingSummaryGenerator.heuristicSummary(from: text)
        }
        guard !isSummarizing else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        let refined = await ThinkingSummaryGenerator.summarize(text)
        guard !Task.isCancelled else { return }
        if !refined.isEmpty {
            resolvedSummary = refined
        }
    }

    private func copyThinking() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = trimmed
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        withAnimation(.easeOut(duration: 0.15)) {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.2)) {
                showCopiedToast = false
            }
        }
    }
}
