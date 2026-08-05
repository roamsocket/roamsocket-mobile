import SwiftUI
import MobileAICore

/// Captured assistant outputs that meet the artifact threshold (≥ 10 lines
/// or contains a code block). Tap an item to see it full-screen with copy.
struct ArtifactsListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if state.artifactStore.artifacts.isEmpty {
                empty
            } else {
                List {
                    ForEach(state.artifactStore.artifacts) { artifact in
                        NavigationLink {
                            ArtifactDetailView(artifact: artifact)
                        } label: {
                            row(for: artifact)
                        }
                        .listRowBackground(Theme.surface)
                        .swipeActions {
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

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text("No artifacts yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Long assistant replies and code blocks you receive in chat will appear here automatically.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxHeight: .infinity)
    }

    private func row(for artifact: Artifact) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(artifact.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("\(artifact.lineCount) lines")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                Text("·")
                    .foregroundStyle(Theme.textTertiary)
                Text(artifact.createdAt, style: .date)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Read-only full-screen view of an artifact with a copy button.
struct ArtifactDetailView: View {
    let artifact: Artifact

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                Text(artifact.content)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
        }
        .navigationTitle(artifact.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
