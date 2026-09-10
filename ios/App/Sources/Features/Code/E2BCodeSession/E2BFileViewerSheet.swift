import SwiftUI
import AnyProvCore

/// Read-only file viewer for the E2B code session.
/// Fetches the file's contents from the live sandbox
/// via `DirectE2BClient.readFile` and renders them
/// in a scrollable monospaced view. The same component
/// is also the destination for the "view file" tap on
/// a `write_file` / `edit_file` tool card (the runner
/// already has the post-edit content; the view is
/// passed that path and refetches so the viewer is
/// always authoritative against the live sandbox).
struct E2BFileViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: E2bCodeSession
    let clientProvider: () -> DirectE2BClient?
    let path: String
    @State private var contents: String?
    @State private var isLoading: Bool = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await load() }
        }
        .presentationDetents([.large])
    }

    private var displayName: String {
        // Title shows the relative path (the sheet
        // is presented from the file list, which is
        // already under `/code`).
        path
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading \(path)…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textTertiary)
                Text(error)
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let contents {
            ScrollView {
                Text(contents)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Theme.background)
        }
    }

    private func load() async {
        guard let client = clientProvider() else {
            isLoading = false
            error = "Add your e2b.dev API key in Settings → Sandboxes (E2B) first."
            return
        }
        guard let sandboxId = session.sandboxId, !sandboxId.isEmpty else {
            isLoading = false
            error = "Sandbox is no longer live. Reopen the session to read files."
            return
        }
        isLoading = true
        error = nil
        do {
            // Always fetch the absolute path. The file
            // list hands us paths relative to `/code`
            // (e.g. `src/main.py`); `readFile` expects
            // the full sandbox path (`/code/src/main.py`).
            let absolute = path.hasPrefix("/") ? path : "/code/\(path)"
            contents = try await client.readFile(
                sandboxId: sandboxId,
                accessToken: session.sandboxAccessToken,
                path: absolute
            )
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
