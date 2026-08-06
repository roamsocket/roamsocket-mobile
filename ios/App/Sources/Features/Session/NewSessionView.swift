import SwiftUI
import AnyProvCore

/// Full-screen composer shown after tapping "New session".
/// Repository selection, suggestions, permission mode, and the first task all
/// live here so starting a coding session never goes through the LLM-question UI.
struct NewSessionView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var onStart: (SessionConfig, String) -> Void

    @State private var task = ""
    @State private var showRepositoryPicker = false
    @State private var showGitHubLink = false
    @State private var showServerPairing = false
    @State private var showModelPicker = false
    @State private var showPermissionPicker = false
    @State private var showProviderSettings = false
    @State private var showEnvironmentPicker = false
    @State private var errorMessage: String?
    @FocusState private var composerFocused: Bool

    private let suggestions = [
        "Create or update my AGENTS.md file",
        "Search for a TODO comment and fix it",
        "Recommend areas to improve our tests",
    ]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                // Dock suggestions + repo + composer to the bottom so the page
                // doesn't float mid-screen with a large empty gap.
                GeometryReader { geo in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            suggestionsSection
                            repoControls
                            composer
                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 4)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottom)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showRepositoryPicker) {
            RepositoryPickerSheet()
        }
        .sheet(isPresented: $showGitHubLink, onDismiss: {
            // After a successful link, continue into the repo picker.
            // Defer so SwiftUI finishes dismissing this sheet before presenting
            // the next one.
            guard isGitHubLinked else { return }
            DispatchQueue.main.async {
                showRepositoryPicker = true
            }
        }) {
            NavigationStack { GitHubLinkView() }
        }
        .sheet(isPresented: $showServerPairing, onDismiss: {
            // After a successful pair, retry starting the session so the user
            // doesn't have to hit Send again. Defer so the pairing sheet fully
            // dismisses first.
            guard isServerPaired else { return }
            DispatchQueue.main.async {
                start()
            }
        }) {
            NavigationStack { ServerPairingView() }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet()
        }
        .sheet(isPresented: $showPermissionPicker) {
            PermissionModeSheet(selection: $state.permissionMode)
        }
        .sheet(isPresented: $showProviderSettings) {
            AppSettingsView(initialFocus: .providers)
        }
        .sheet(isPresented: $showEnvironmentPicker) {
            EnvironmentPickerSheet()
        }
        .onChange(of: state.selectedRepo?.fullName) { _, _ in
            errorMessage = nil
        }
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 6) {
                Button(action: { showEnvironmentPicker = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "cloud")
                        Text(state.selectedEnvironment?.name ?? "Choose environment")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(state.selectedEnvironment == nil ? Theme.textTertiary : Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose environment")
            }

            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 48, height: 48)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Divider().overlay(Theme.separator)
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggestions")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)

            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    task = suggestion
                    composerFocused = true
                } label: {
                    Text(suggestion)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 15)
                        .background(Theme.surfaceElevated, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var repoControls: some View {
        HStack(spacing: 10) {
            Button(action: chooseRepository) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 46, height: 46)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose repository")

            Button(action: chooseRepository) {
                HStack(spacing: 8) {
                    GitHubGlyph()
                    Text(state.selectedRepo?.fullName ?? "Choose repository")
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(state.selectedRepo == nil ? Theme.textSecondary : Theme.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isGitHubLinked: Bool {
        state.githubToken?.isEmpty == false
    }

    private var isServerPaired: Bool {
        state.serverEndpoint != nil && state.serverToken != nil
    }

    /// Opens the repo picker when GitHub is linked; otherwise the link modal.
    private func chooseRepository() {
        if isGitHubLinked {
            showRepositoryPicker = true
        } else {
            showGitHubLink = true
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Start compact (~one to two lines) and grow with content up to the
            // previous max height so the empty state isn't a large empty box.
            TextField("Code anything…", text: $task, axis: .vertical)
                .lineLimit(1...6)
                .font(.system(size: 18))
                .foregroundStyle(Theme.textPrimary)
                .focused($composerFocused)
                .frame(minHeight: 44, maxHeight: 150, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)

            HStack(spacing: 8) {
                Button(action: {}) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(Theme.background, in: Circle())
                }
                .buttonStyle(.plain)

                ModelSelectorPill(
                    modelDisplayName: modelPillTitle,
                    onPick: { showModelPicker = true },
                    onAddModel: { showProviderSettings = true }
                )

                Button(action: { showPermissionPicker = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: state.permissionMode.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(state.permissionMode.displayName)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.background, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button(action: start) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(canSubmit ? Theme.background : Theme.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(canSubmit ? Theme.accent : Theme.background, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Theme.separator, lineWidth: 1))
    }

    private var canSubmit: Bool {
        !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modelPillTitle: String {
        guard let name = state.selectedModel?.displayName else { return "" }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for effort in Effort.allCases.reversed() {
            let suffix = " " + effort.displayName
            if trimmed.lowercased().hasSuffix(suffix.lowercased()) {
                return String(trimmed.dropLast(suffix.count))
            }
        }
        return trimmed
    }

    private func start() {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else { return }

        // No desktop server attached — open pairing instead of a dead-end error.
        guard isServerPaired else {
            errorMessage = nil
            showServerPairing = true
            return
        }

        guard let config = SessionLauncher.makeConfig(in: state, task: trimmedTask) else {
            errorMessage = SessionLauncher.missingRequirements(in: state).joined(separator: " ")
            return
        }
        onStart(config, trimmedTask)
        dismiss()
    }
}

/// Permission mode chooser shared by the new-session and in-session composers.
struct PermissionModeSheet: View {
    @Binding var selection: PermissionMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "Select mode", trailing: nil, onClose: { dismiss() }) {
            VStack(spacing: 0) {
                modeRow(
                    .ask,
                    icon: "bolt",
                    tint: Theme.accent,
                    title: "Auto",
                    subtitle: "The agent handles permission decisions"
                )
                Divider().overlay(Theme.separator).padding(.leading, 64)
                modeRow(
                    .acceptEdits,
                    icon: "chevron.left.forwardslash.chevron.right",
                    tint: .purple,
                    title: "Accept edits",
                    subtitle: "Automatically accept all file edits"
                )
                Divider().overlay(Theme.separator).padding(.leading, 64)
                modeRow(
                    .plan,
                    icon: "list.bullet.clipboard",
                    tint: Theme.selection,
                    title: "Plan",
                    subtitle: "Create a plan before making changes"
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Spacer()
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
    }

    private func modeRow(
        _ mode: PermissionMode,
        icon: String,
        tint: Color,
        title: String,
        subtitle: String
    ) -> some View {
        Button {
            selection = mode
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if selection == mode {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.selection)
                }
            }
            .padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
