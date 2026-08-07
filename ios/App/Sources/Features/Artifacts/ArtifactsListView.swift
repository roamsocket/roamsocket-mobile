import SwiftUI
import AnyProvCore

/// Captured assistant outputs that meet the artifact threshold (≥ 10 lines
/// or contains a code block). Opening an item jumps to the source chat,
/// scrolls to the producing message, and opens a split artifact panel.
struct ArtifactsListView: View {
    @EnvironmentObject var state: AppState
    /// When set, opening an artifact loads that chat and pops back to root chat.
    var history: ChatHistoryStore?
    var path: Binding<[RootRoute]>?
    var onOpenedInChat: (() -> Void)?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if state.artifactStore.artifacts.isEmpty {
                empty
            } else {
                List {
                    ForEach(state.artifactStore.artifacts) { artifact in
                        Button {
                            open(artifact)
                        } label: {
                            artifactCard(artifact)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                state.artifactStore.delete(artifact.id)
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
        .navigationTitle("Artifacts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !state.artifactStore.artifacts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            state.artifactStore.clearAll()
                        } label: {
                            Label("Clear all", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
        }
    }

    private func open(_ artifact: Artifact) {
        if let chatId = artifact.chatId, let history {
            // Prefer global recents; project chats still set active id so load can resolve.
            if let item = history.recents.first(where: { $0.id == chatId }) {
                history.openChat(item)
            } else {
                history.activeChatID = chatId
            }
        }
        state.presentArtifact(artifact)
        path?.wrappedValue = []
        onOpenedInChat?()
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text("No artifacts yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Long assistant replies and code blocks you receive in chat will appear here automatically. Tap one to open it beside the original message.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxHeight: .infinity)
    }

    /// Compact single-line card — title + meta, not a multi-line preview block.
    private func artifactCard(_ artifact: Artifact) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(artifact.lineCount) lines")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    Text("·")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    Text(artifact.createdAt, style: .date)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    if artifact.chatId != nil {
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                        Text("In chat")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.separator.opacity(0.55), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// Read-only document panel for the chat split view (and standalone navigation).
struct ArtifactDetailView: View {
    let artifact: Artifact
    var onClose: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Artifact")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .textCase(.uppercase)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = artifact.content
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(Theme.textPrimary)
                    }
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 32, height: 32)
                                .background(Theme.surfaceElevated, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

                Text(artifact.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                ScrollView {
                    Text(artifact.content)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(16)
                }
            }
        }
        .navigationTitle(artifact.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onClose == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = artifact.content
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
        }
    }
}
