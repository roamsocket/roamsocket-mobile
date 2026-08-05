import SwiftUI

/// Project detail screen mirroring the third screenshot.
struct ProjectDetailView: View {
    let project: ProjectItem
    @ObservedObject var history: ChatHistoryStore
    @State private var showInstructions: Bool = false
    @State private var showFiles: Bool = false
    @State private var showAddFileSheet: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                pillRow
                chatList
            }

            newChatButton
                .padding(.trailing, 16)
                .padding(.bottom, 24)
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showInstructions) {
            InstructionsSheet()
        }
        .sheet(isPresented: $showAddFileSheet) {
            ProjectFilesSheet()
        }
    }

    private var pillRow: some View {
        HStack(spacing: 8) {
            Pill(title: "Add files", systemImage: nil) { showAddFileSheet = true }
                .frame(maxWidth: .infinity)
            Pill(title: "Instructions", systemImage: nil) { showInstructions = true }
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var chatList: some View {
        let chats = history.chats(for: project)
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(chats) { chat in
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

                    if chat.id != chats.last?.id {
                        Divider()
                            .background(Theme.separator)
                            .padding(.leading, 16)
                    }
                }
            }
        }
    }

    private var newChatButton: some View {
        Button(action: { history.startNewChat() }) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                Text("New chat")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.white, in: Capsule())
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Bottom sheet for editing project instructions (mirrors 4th screenshot).
private struct InstructionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = "Always say that our users are the ones who\nchoose the charities. Also day business is\ndonate what you want."

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
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
                    Text("Instructions")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(Theme.surface)
                    if text.isEmpty {
                        Text("Instruct Claude how to behave and respond for all of the chats within this project.")
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
                .frame(height: 200)
                .padding(.horizontal, 16)

                Spacer()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
    }
}

/// Bottom sheet for project files (mirrors 5th screenshot).
private struct ProjectFilesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
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
                    Text("Project Files")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Spacer()

                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Theme.surfaceElevated)
                            .frame(width: 56, height: 56)
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text("No files yet")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Add files for Claude to use in this project.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
    }
}
