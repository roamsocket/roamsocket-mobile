import SwiftUI
import UIKit

/// Collapsible container for a message's tool calls. Default state
/// is collapsed: a single summary row shows the count + status (e.g.
/// "Ran 3 tools" / "Running web search…" / "1 tool failed"). Tapping
/// the row expands inline to reveal each tool's summary + detail
/// underneath; tap again to collapse.
///
/// Mirrors `ThinkingBlock` so the chat surface has a consistent
/// disclosure pattern for both reasoning and tool-use.
struct ToolCallsBlock: View {
    let calls: [ToolCall]
    /// SF Symbol for each tool name. Passed in so the icon mapping
    /// stays in the message view (which already knows the taxonomy).
    let iconForTool: (ToolCall) -> String

    @State private var isExpanded: Bool = false

    private var summary: String {
        let running = calls.filter {
            if case .running = $0.status { return true }
            if case .pending = $0.status { return true }
            return false
        }
        if !running.isEmpty, running.count == calls.count {
            // Every tool still in flight — show a live label.
            if let first = running.first {
                return "Running \(first.summary.lowercased())…"
            }
            return "Running tools…"
        }
        let failed = calls.filter {
            if case .failed = $0.status { return true }
            return false
        }
        if !failed.isEmpty, failed.count == calls.count {
            return "\(calls.count) tool\(calls.count == 1 ? "" : "s") failed"
        }
        if !failed.isEmpty {
            return "Ran \(calls.count) tool\(calls.count == 1 ? "" : "s") (\(failed.count) failed)"
        }
        if running.isEmpty {
            return "Ran \(calls.count) tool\(calls.count == 1 ? "" : "s")"
        }
        return "Ran \(calls.count) tool\(calls.count == 1 ? "" : "s") (\(running.count) running)"
    }

    private var isStillWorking: Bool {
        calls.contains {
            if case .running = $0.status { return true }
            if case .pending = $0.status { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryRow

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(calls) { call in
                        row(for: call)
                    }
                }
                .padding(.leading, 24) // align under the summary, past the icon
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isExpanded)
    }

    // MARK: - Subviews

    private var summaryRow: some View {
        HStack(alignment: .center, spacing: 8) {
            if isStillWorking {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16, height: 16)
            }

            Text(summary)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary.opacity(0.75))
                .contentTransition(.symbolEffect(.replace))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isExpanded.toggle()
        }
        .contextMenu {
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
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(summary)
        .accessibilityHint(isExpanded ? "Tap to collapse" : "Tap to expand")
    }

    private func row(for call: ToolCall) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if case .running = call.status {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: iconForTool(call))
                        .font(.system(size: 12, weight: .regular))
                }
            }
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 16, height: 16)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(call.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let detail = call.detail,
                   !detail.isEmpty,
                   call.status == .completed || isFailed(call.status)
                {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary.opacity(0.85))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: call))
    }

    private func isFailed(_ status: ToolCall.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func accessibilityLabel(for call: ToolCall) -> String {
        var parts = [call.summary]
        if let detail = call.detail, !detail.isEmpty {
            parts.append(detail)
        }
        switch call.status {
        case .running: parts.append("in progress")
        case .pending: parts.append("pending")
        case .failed: parts.append("failed")
        case .completed: break
        }
        return parts.joined(separator: ", ")
    }
}
