import SwiftUI

/// Project detail: chats list + Instructions / Memory sheets (Claude-style).
struct ProjectDetailView: View {
    let project: ProjectItem
    @ObservedObject var history: ChatHistoryStore
    @EnvironmentObject var state: AppState
    @State private var showInstructions: Bool = false
    @State private var showMemory: Bool = false
    @State private var renameTarget: ProjectChatItem?

    @Binding var path: [RootRoute]

    private var liveProject: ProjectItem {
        history.projects.first(where: { $0.id == project.id }) ?? project
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                pillRow
                memoryBanner
                chatList
            }

            newChatButton
                .padding(.trailing, 16)
                .padding(.bottom, 24)
        }
        .navigationTitle(liveProject.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showInstructions) {
            ProjectInstructionsSheet(
                projectName: liveProject.name,
                initialText: liveProject.instructions
            ) { text in
                history.updateProjectInstructions(projectID: project.id, instructions: text)
            }
        }
        .sheet(isPresented: $showMemory) {
            ProjectMemorySheet(
                projectName: liveProject.name,
                initialMemory: liveProject.memory
            ) { memory in
                history.updateProjectMemory(projectID: project.id, memory: memory)
            } onCommand: { cmd in
                history.applyProjectMemoryCommand(projectID: project.id, command: cmd)
            }
        }
        .sheet(item: $renameTarget) { chat in
            RenameChatSheet(
                initialTitle: chat.title,
                onGenerate: {
                    await history.suggestTitle(projectID: project.id, chatID: chat.id)
                },
                onSave: { title in
                    history.renameProjectChat(
                        projectID: project.id,
                        chatID: chat.id,
                        title: title
                    )
                    renameTarget = nil
                },
                onCancel: {
                    renameTarget = nil
                }
            )
        }
    }

    private var pillRow: some View {
        ProjectDetailPill(
            title: "Instructions",
            systemImage: nil,
            action: { showInstructions = true }
        )
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Compact memory preview card under the pills.
    private var memoryBanner: some View {
        Button { showMemory = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Memory")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("Only you")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(memoryPreviewText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let updated = liveProject.memoryUpdatedAt {
                    Text("Last updated \(relativeTime(updated))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var memoryPreviewText: String {
        let m = liveProject.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty { return "Project memory will show here after a few chats. Tap to manage." }
        return m
    }

    private var chatList: some View {
        let chats = history.chats(for: project)
        return Group {
            if chats.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(chats) { chat in
                        chatRow(chat)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                history.activeProject = project
                                path.append(.projectChat(project, chat))
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Theme.background)
                            .listRowSeparatorTint(Theme.separator)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    history.archiveProjectChat(projectID: project.id, chatID: chat.id)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(Theme.accent)
                                Button {
                                    renameTarget = chat
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(Theme.textSecondary)
                            }
                            .contextMenu {
                                Button {
                                    renameTarget = chat
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button {
                                    history.archiveProjectChat(projectID: project.id, chatID: chat.id)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                Button(role: .destructive) {
                                    history.deleteProjectChat(projectID: project.id, chatID: chat.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func chatRow(_ chat: ProjectChatItem) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(relativeTime(chat.lastMessageAt))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No chats yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Tap New chat to start a conversation in this project.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var newChatButton: some View {
        Button(action: startNewChat) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                Text("New chat")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.accent, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
    }

    private func startNewChat() {
        let chat = history.startNewChat(in: project, selectedModel: state.selectedModel)
        path.append(.projectChat(project, chat))
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ProjectDetailPill: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }
}

// MARK: - Instructions modal

private struct ProjectInstructionsSheet: View {
    let projectName: String
    let initialText: String
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("Set project instructions")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Text("Provide relevant instructions for chats within \(projectName). Works alongside profile instructions and the selected style.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.surface)
                    if text.isEmpty {
                        Text("Think step by step and show reasoning for complex problems. Use specific examples.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(16)
                    }
                    TextEditor(text: $text)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(12)
                }
                .frame(minHeight: 200)
                .padding(.horizontal, 16)

                Spacer()

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                    Button("Save instructions") {
                        onSave(text)
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
                }
                .padding(16)
            }
        }
        .onAppear { text = initialText }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Memory modal

private struct ProjectMemorySheet: View {
    let projectName: String
    let initialMemory: String
    var onSave: (String) -> Void
    var onCommand: (String) -> String

    @Environment(\.dismiss) private var dismiss
    @State private var memory: String = ""
    @State private var command: String = ""
    @State private var placeholderIndex: Int = 0
    @State private var isCommandFocused: Bool = false

    private static let placeholders: [String] = [
        "Tell us what to adjust in our memory",
        "forget *example*",
        "remember that I *example*",
        "remember that I prefer concise answers",
        "forget my old job title",
        "Don't bring up my former baseball career…",
        "remember that I work on kind365",
        "forget confidential client names",
    ]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Manage project memory")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

                Text("Memory is private on this device. Use the field below to forget or remember facts for \(projectName).")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                ScrollView {
                    TextEditor(text: $memory)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minHeight: 220)
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 16)
                }

                // Cycling adjust field
                HStack(spacing: 8) {
                    TextField(currentPlaceholder, text: $command, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .onSubmit { applyCommand() }
                    Button(action: applyCommand) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 36, height: 36)
                            .background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surfaceElevated, in: Capsule())
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Button("Done") {
                    onSave(memory)
                    dismiss()
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent, in: Capsule())
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .onAppear {
            memory = initialMemory
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                if command.isEmpty {
                    placeholderIndex = (placeholderIndex + 1) % Self.placeholders.count
                }
            }
        }
        .presentationDetents([.large, .medium])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
    }

    private var currentPlaceholder: String {
        Self.placeholders[placeholderIndex % Self.placeholders.count]
    }

    private func applyCommand() {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        onSave(memory)
        let next = onCommand(cmd)
        memory = next
        command = ""
    }
}


