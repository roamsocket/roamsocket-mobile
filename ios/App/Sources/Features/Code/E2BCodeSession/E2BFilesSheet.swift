import SwiftUI
import AnyProvCore

/// Files sheet for an E2B code session. Lists the
/// repo's working tree (under `/code`) and lets the
/// user tap a file to read it.
///
/// Mirrors the desktop session's "Files" tab in
/// spirit — the desktop shows a recursive tree in a
/// side panel; the phone shows a flat list with
/// collapsible directories so a long file path fits
/// on one line. The underlying fetch is a single
/// `listFiles` call against the sandbox (capped at
/// 500 results; the cap matches `DirectE2BClient`'s
/// default so a pathological `**/*` doesn't blow up
/// the sheet). For the v1 phone UX, that's plenty
/// for the typical repo; a follow-up can paginate or
/// lazily walk the tree if it turns out a common
/// project has > 500 files at the top level.
struct E2BFilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: E2bCodeSession
    /// Provided by the view's parent so the sheet
    /// can read the user's e2b API key (the
    /// `E2bSessionStore` resolves it at call time, so
    /// a key saved after the sheet opened is picked
    /// up without restarting the fetch).
    let clientProvider: () -> DirectE2BClient?
    @State private var files: [String] = []
    @State private var isLoading: Bool = true
    @State private var error: String?
    @State private var openedFile: OpenedFile?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await load() }
                .sheet(item: $openedFile) { opened in
                    E2BFileViewerSheet(
                        session: session,
                        clientProvider: clientProvider,
                        path: opened.path
                    )
                }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading \(session.repoFullName)@\(session.branch)…")
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
        } else if files.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textTertiary)
                Text("No files found")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("The sandbox is up but `**/*` returned no files. The agent can still use `run_shell` to inspect the tree.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fileList
        }
    }

    /// Flat list with disclosure groups per top-level
    /// directory. Each row is a file path; tapping it
    /// opens the file viewer sheet.
    private var fileList: some View {
        List {
            ForEach(groupedFiles(), id: \.dir) { group in
                Section(group.dir) {
                    ForEach(group.paths, id: \.self) { path in
                        Button {
                            openedFile = OpenedFile(path: path)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                                Text(path)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Group files by their first path component so
    /// long file lists render as a handful of
    /// top-level directories (each shown as a
    /// section). Files at the repo root go into
    /// "(root)".
    private struct DirGroup {
        let dir: String
        let paths: [String]
    }

    private func groupedFiles() -> [DirGroup] {
        var byDir: [String: [String]] = [:]
        for path in files {
            let firstSlash = path.firstIndex(of: "/")
            let dir: String
            if let slash = firstSlash {
                dir = String(path[..<slash])
            } else {
                dir = "(root)"
            }
            byDir[dir, default: []].append(path)
        }
        // Sort dirs alphabetically, "(root)" first.
        let keys = byDir.keys.sorted { lhs, rhs in
            if lhs == "(root)" { return true }
            if rhs == "(root)" { return false }
            return lhs < rhs
        }
        return keys.map { key in
            let paths = byDir[key] ?? []
            // Sort each dir's files alphabetically so the
            // list is deterministic across fetches.
            return DirGroup(dir: key, paths: paths.sorted())
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
            let matches = try await client.listFiles(
                sandboxId: sandboxId,
                accessToken: session.sandboxAccessToken,
                pattern: "**/*",
                cwd: "/code"
            )
            files = matches
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Identifies the file the sheet has open. The
    /// `.sheet(item:)` modifier hands the value to
    /// the viewer.
    private struct OpenedFile: Identifiable, Hashable {
        let path: String
        var id: String { path }
    }
}
