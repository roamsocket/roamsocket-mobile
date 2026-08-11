import SwiftUI

/// Sheet presented from the chat toolbar incognito button.
///
/// When the active chat is a regular chat, picking a lifetime starts a new
/// incognito chat with that schedule. When the active chat is already
/// incognito, the current schedule is shown (with a checkmark) and can be
/// changed, or the chat can be forgotten immediately.
struct IncognitoChatSheet: View {
    @ObservedObject var history: ChatHistoryStore
    /// Start a new incognito chat with the chosen lifetime.
    var onStartIncognito: (IncognitoLifetime) -> Void
    /// Start a fresh regular chat (used after "Forget this chat now").
    var onStartFresh: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// The active chat when it is an incognito chat.
    private var activeIncognito: ChatHistoryItem? {
        guard let id = history.activeChatID else { return nil }
        return history.recents.first { $0.id == id && $0.isIncognito }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                List {
                    ForEach(IncognitoLifetime.allCases) { lifetime in
                        Button {
                            select(lifetime)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "theatermasks.fill")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lifetime.title)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(lifetime.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer(minLength: 0)
                                if activeIncognito?.incognitoLifetime == lifetime {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                if activeIncognito != nil {
                    Button(role: .destructive) {
                        if let id = activeIncognito?.id {
                            history.forgetChatNow(id)
                        }
                        dismiss()
                        onStartFresh()
                    } label: {
                        Text("Forget this chat now")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .background(Theme.background)
            .navigationTitle("Incognito chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Private by default")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Incognito chats work like normal chats, but the transcript is deleted automatically.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func select(_ lifetime: IncognitoLifetime) {
        if let active = activeIncognito {
            history.setIncognitoLifetime(lifetime, for: active.id)
        } else {
            onStartIncognito(lifetime)
        }
        dismiss()
    }
}

#Preview {
    IncognitoChatSheet(
        history: ChatHistoryStore(),
        onStartIncognito: { _ in },
        onStartFresh: {}
    )
}
