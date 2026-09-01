import SwiftUI
import AnyProvCore

/// Permission mode picker sheet used inside the desktop-mediated
/// `SessionView` (the chat → code-session fullScreenCover). The
/// Code home no longer surfaces this — that path is E2B-only and
/// doesn't run the desktop agent loop.
struct PermissionModeSheet: View {
    @Binding var selection: PermissionMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach([PermissionMode.acceptEdits, .plan, .ask], id: \.self) { mode in
                    Button {
                        selection = mode
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 17, weight: .regular))
                                .frame(width: 22)
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.displayName)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(mode.subtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if selection == mode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Permission mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private extension PermissionMode {
    var subtitle: String {
        switch self {
        case .acceptEdits: return "Edit files and run commands without asking."
        case .plan: return "Show a plan before any edit or command."
        case .ask: return "Ask before any edit or command."
        }
    }
}

/// Compact git / session status pill shared by `SessionView` and the
/// commit / push / PR strip. Kept here next to the other desktop-
/// session helpers so the chat → code-session flow stays intact.
struct SessionGitStatusBadge: View {
    let icon: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.15), in: Capsule())
        .accessibilityLabel(label)
    }

    /// Map a persisted session status to a lightweight badge.
    static func forSessionStatus(_ status: CodeSession.Status) -> SessionGitStatusBadge {
        switch status {
        case .working:
            return SessionGitStatusBadge(
                icon: "arrow.up.circle.fill",
                label: "ahead",
                tint: Theme.accent
            )
        case .needsInput:
            return SessionGitStatusBadge(
                icon: "exclamationmark.circle.fill",
                label: "blocked",
                tint: .orange
            )
        case .readyForReview:
            return SessionGitStatusBadge(
                icon: "checkmark.circle.fill",
                label: "ready",
                tint: Theme.selection
            )
        case .completed:
            return SessionGitStatusBadge(
                icon: "checkmark.seal.fill",
                label: "merged",
                tint: Theme.textSecondary
            )
        case .archived:
            return SessionGitStatusBadge(
                icon: "archivebox.fill",
                label: "archived",
                tint: Theme.textTertiary
            )
        }
    }

    /// Live badge for an open coding session (diff / PR / agent state).
    static func live(
        isRunning: Bool,
        hasDiffs: Bool,
        hasPR: Bool,
        needsInput: Bool
    ) -> SessionGitStatusBadge {
        if needsInput {
            return forSessionStatus(.needsInput)
        }
        if hasPR {
            return SessionGitStatusBadge(
                icon: "arrow.triangle.branch",
                label: "pr open",
                tint: Theme.selection
            )
        }
        if isRunning {
            return forSessionStatus(.working)
        }
        if hasDiffs {
            return SessionGitStatusBadge(
                icon: "arrow.up.circle.fill",
                label: "ahead",
                tint: Theme.accent
            )
        }
        return SessionGitStatusBadge(
            icon: "checkmark.circle",
            label: "clean",
            tint: Theme.textSecondary
        )
    }
}
