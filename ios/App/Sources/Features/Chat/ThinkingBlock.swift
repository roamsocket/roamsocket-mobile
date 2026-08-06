import SwiftUI
import UIKit

/// Claude-style thinking row: clock on the left, grey summary, chevron on the right.
/// No card/bubble. Tap opens a **Thought process** sheet with the full reasoning.
///
/// When `text` is empty (open tag with no body yet), shows a non-interactive
/// grey **Thinking...** row so raw markup never leaks.
struct ThinkingBlock: View {
    /// Full reasoning body.
    let text: String
    /// Optional precomputed one-line label (from Apple Foundation Models).
    var summary: String? = nil
    /// When true, also show full reasoning inline under the row
    /// (Settings → Always expand thinking).
    var expanded: Bool = false

    @State private var showSheet = false
    @State private var resolvedSummary: String = ""
    @State private var isSummarizing = false
    @State private var showCopiedToast = false

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

            if hasBody, expanded {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: expanded)
        .task(id: summaryTaskID) {
            await refreshSummaryIfNeeded()
        }
        .sheet(isPresented: $showSheet) {
            ThoughtProcessSheet(text: text) {
                showSheet = false
            }
        }
    }

    // MARK: - Row

    private var summaryRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16, height: 16)

            Text(displaySummary)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showCopiedToast {
                Text("Copied")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .transition(.opacity)
            } else if hasBody {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary.opacity(0.75))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasBody else { return }
            showSheet = true
        }
        .onLongPressGesture(minimumDuration: 0.4, perform: copyThinking)
        .contextMenu {
            if hasBody {
                Button {
                    showSheet = true
                } label: {
                    Label("View thought process", systemImage: "text.alignleft")
                }
                Button {
                    copyThinking()
                } label: {
                    Label("Copy thinking", systemImage: "doc.on.doc")
                }
            }
        }
        .accessibilityAddTraits(hasBody ? .isButton : [])
        .accessibilityLabel(hasBody ? "Thought process: \(displaySummary)" : "Thinking")
        .accessibilityHint(hasBody ? "Shows the model’s private reasoning" : "Model is reasoning")
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

// MARK: - Full thought process sheet (Claude-style)

private struct ThoughtProcessSheet: View {
    let text: String
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Thought process")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.textTertiary)
                            .font(.system(size: 22))
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = text
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Copy thought process")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.surface)
    }
}
