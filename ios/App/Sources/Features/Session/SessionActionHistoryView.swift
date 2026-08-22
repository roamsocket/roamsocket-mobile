import SwiftUI

// MARK: - Transcript segment
//
// The Code session transcript previously rendered one card per tool call,
// which made the chat scroll quickly when the agent ran many commands.
// `TranscriptSegment` collapses any contiguous run of `.tool` items into a
// single renderable chunk (`actions`); non-tool items pass through as their
// own segment. The session view walks segments instead of raw items, so the
// inline transcript stays compact and the full list moves into a sheet.

/// One renderable chunk of the coding-session transcript. Either a single
/// non-tool item rendered as before, or a contiguous run of tool items
/// collapsed into one "action group" card.
enum TranscriptSegment: Identifiable {
    case item(SessionViewModel.Item)
    case actions(id: String, tools: [SessionViewModel.Item])

    var id: String {
        switch self {
        case .item(let item):
            return item.id
        case .actions(let id, _):
            return id
        }
    }

    /// Group consecutive `.tool` items into `actions` segments. Non-tool
    /// items stay as single-item segments. Preserves order.
    ///
    /// The action group id is anchored to the first tool's id, so it stays
    /// stable as the group grows and SwiftUI can animate the change instead
    /// of tearing down and rebuilding the row.
    static func segments(from items: [SessionViewModel.Item]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var pendingTools: [SessionViewModel.Item] = []
        for item in items {
            switch item {
            case .tool:
                pendingTools.append(item)
            default:
                if !pendingTools.isEmpty {
                    segments.append(makeActionGroup(from: pendingTools))
                    pendingTools = []
                }
                segments.append(.item(item))
            }
        }
        if !pendingTools.isEmpty {
            segments.append(makeActionGroup(from: pendingTools))
        }
        return segments
    }

    private static func makeActionGroup(from tools: [SessionViewModel.Item]) -> TranscriptSegment {
        let firstID = tools.first?.id ?? "empty"
        return .actions(id: "g-\(firstID)", tools: tools)
    }
}

// MARK: - Item payload helpers
//
// The session view model stores tool payloads in an enum with associated
// values. These computed accessors let the action-history views read those
// fields without re-implementing the case match everywhere — and stay safe
// when the item is not actually a tool (returns nil for everything).

extension SessionViewModel.Item {
    /// True when this item is a tool call.
    var isTool: Bool {
        if case .tool = self { return true }
        return false
    }

    /// Tool name (`bash`, `read_file`, …) when this is a tool item; nil otherwise.
    var toolName: String? {
        if case let .tool(_, name, _, _, _) = self { return name }
        return nil
    }

    /// Human-readable summary (e.g. the command or file path).
    var toolSummary: String? {
        if case let .tool(_, _, summary, _, _) = self { return summary }
        return nil
    }

    /// Final status once the tool returns: `true` success, `false` failure,
    /// `nil` while still running.
    var toolOk: Bool? {
        if case let .tool(_, _, _, ok, _) = self { return ok }
        return nil
    }

    /// Captured output (stdout / stderr / diff snippet). May be nil or empty.
    var toolOutput: String? {
        if case let .tool(_, _, _, _, output) = self { return output }
        return nil
    }
}

// MARK: - Action group card

/// Collapsed card that represents one or more tool actions taken by the
/// agent. Shows the count, the most recent action's summary, and aggregate
/// status badges. Tapping the card opens the full history in a sheet.
struct ActionGroupCard: View {
    let tools: [SessionViewModel.Item]
    let onOpenHistory: () -> Void

    private var inFlightCount: Int {
        tools.reduce(0) { acc, item in
            if item.toolOk == nil { return acc + 1 }
            return acc
        }
    }

    private var successCount: Int {
        tools.reduce(0) { acc, item in
            if item.toolOk == true { return acc + 1 }
            return acc
        }
    }

    private var failureCount: Int {
        tools.reduce(0) { acc, item in
            if item.toolOk == false { return acc + 1 }
            return acc
        }
    }

    private var lastToolName: String {
        tools.last?.toolName ?? "tool"
    }

    private var lastSummary: String {
        tools.last?.toolSummary ?? ""
    }

    private var lastIcon: String { Self.icon(for: lastToolName) }

    private var lastStatusColor: Color {
        switch tools.last?.toolOk {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return Theme.accent
        }
    }

    private var isLive: Bool { inFlightCount > 0 }

    var body: some View {
        Button(action: onOpenHistory) {
            HStack(spacing: 12) {
                iconBlock
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(titleText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if isLive {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(Theme.accent)
                        }
                    }
                    Text(lastSummary.isEmpty ? " " : lastSummary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                trailingBadges
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the full history of \(tools.count) action\(tools.count == 1 ? "" : "s")")
    }

    private var iconBlock: some View {
        ZStack {
            Circle()
                .fill(Theme.surfaceElevated)
                .frame(width: 32, height: 32)
            Image(systemName: lastIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(lastStatusColor)
        }
    }

    @ViewBuilder
    private var trailingBadges: some View {
        if failureCount > 0 {
            badge(count: failureCount, color: .red)
        } else if successCount > 0 && !isLive {
            badge(count: successCount, color: .green)
        }
    }

    private func badge(count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var titleText: String {
        if tools.count == 1 { return "1 action" }
        return "\(tools.count) actions"
    }

    private var accessibilityLabel: String {
        if tools.count == 1 {
            return "1 action: \(lastSummary)"
        }
        return "\(tools.count) actions, \(successCount) succeeded, \(failureCount) failed, \(inFlightCount) running. Last: \(lastSummary)"
    }

    /// SF Symbol that best represents a given tool name. Keeps the icon block
    /// honest about what kind of action just ran (terminal for bash, doc
    /// for file reads, folder for lists, etc.).
    static func icon(for tool: String) -> String {
        switch tool {
        case "bash", "shell", "exec": return "terminal"
        case "read_file": return "doc.text"
        case "write_file", "edit_file", "create_file", "patch": return "square.and.pencil"
        case "list_files", "list_dir": return "folder"
        case "grep", "search", "ripgrep": return "magnifyingglass"
        case "web_search", "web_fetch": return "globe"
        case "git": return "arrow.triangle.branch"
        case "skill", "skills": return "sparkles"
        case "mcp", "mcp_call": return "puzzlepiece.extension"
        default: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Action history sheet

/// Modal sheet showing the full ordered list of tool actions for the
/// most recent action group. Each row is tappable to expand its captured
/// output, matching the behavior the old per-tool detail sheet provided.
struct ActionHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let tools: [SessionViewModel.Item]
    @State private var expanded: Set<String> = []

    private var total: Int { tools.count }
    private var inFlight: Int { tools.reduce(0) { $0 + ($1.toolOk == nil ? 1 : 0) } }
    private var success: Int { tools.reduce(0) { $0 + ($1.toolOk == true ? 1 : 0) } }
    private var failure: Int { tools.reduce(0) { $0 + ($1.toolOk == false ? 1 : 0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summaryHeader
                        .listRowBackground(Theme.surface)
                }

                Section {
                    if tools.isEmpty {
                        Text("No actions yet.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .listRowBackground(Theme.surface)
                    } else {
                        ForEach(tools) { item in
                            ActionHistoryRow(
                                item: item,
                                expanded: expanded.contains(item.id),
                                onToggle: { toggle(item) }
                            )
                            .listRowBackground(Theme.surface)
                        }
                    }
                } header: {
                    Text("All actions")
                } footer: {
                    Text("Tap a row to see its captured output. Failures are highlighted in red.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Action history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusPill(count: success, label: "OK", color: .green)
                if failure > 0 {
                    statusPill(count: failure, label: "Failed", color: .red)
                }
                if inFlight > 0 {
                    statusPill(count: inFlight, label: "Running", color: Theme.accent)
                }
                Spacer()
                Text("\(total) total")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusPill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }

    private func toggle(_ item: SessionViewModel.Item) {
        if expanded.contains(item.id) {
            expanded.remove(item.id)
        } else {
            expanded.insert(item.id)
        }
    }
}

/// One row in the action history sheet. Compact by default; tap to expand
/// and see the captured output, with copy-to-clipboard via long-press.
private struct ActionHistoryRow: View {
    let item: SessionViewModel.Item
    let expanded: Bool
    let onToggle: () -> Void

    private var tool: String { item.toolName ?? "tool" }
    private var summary: String { item.toolSummary ?? "" }
    private var ok: Bool? { item.toolOk }
    private var output: String? { item.toolOutput }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ActionGroupCard.icon(for: tool))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(toolLabel)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                        Text(summary)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .padding(.top, 4)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if let output, !output.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(output)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 6)
                } else {
                    Text("No output yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 4)
                }
            }
        }
        .contextMenu {
            if let output, !output.isEmpty {
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = output
                    #endif
                } label: {
                    Label("Copy output", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var toolLabel: String {
        switch tool {
        case "bash", "shell", "exec": return "Bash"
        case "read_file", "write_file", "edit_file", "create_file", "patch": return "File"
        case "list_files", "list_dir": return "List"
        case "grep", "search", "ripgrep": return "Search"
        case "web_search": return "Web search"
        case "web_fetch": return "Web fetch"
        case "git": return "Git"
        default: return tool
        }
    }

    private var statusColor: Color {
        switch ok {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return Theme.accent
        }
    }
}
