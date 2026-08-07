import SwiftUI
import AnyProvCore

/// Full-screen Memory manager (Settings → Memory → Manage memory).
/// Toggles, import, structured entries, freeform add — Claude-style.
struct ManageMemoryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var userMemory = UserMemoryStore.shared

    @State private var showMemoryImport = false
    @State private var memoryDetailID: String?
    @State private var memoryDraft = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    preferencesCard
                    importCard
                    entriesCard
                    draftCard
                    Text("Memory is stored on this device. Project Instructions and chat history still apply when these toggles are off.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .navigationTitle("Manage memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                }
            }
            .sheet(isPresented: $showMemoryImport) {
                MemoryImportSheet { text in
                    _ = userMemory.importFromText(text)
                }
            }
            .sheet(item: Binding(
                get: { memoryDetailID.map { MemoryDetailRoute(id: $0) } },
                set: { memoryDetailID = $0?.id }
            )) { route in
                MemoryEntryDetailSheet(entryID: route.id, store: userMemory)
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
    }

    // MARK: - Cards

    private var preferencesCard: some View {
        card {
            ToggleRow(
                systemImage: "magnifyingglass",
                title: "Search and reference chats",
                subtitle: "Allow the assistant to search for relevant details in past chats.",
                iconColor: Theme.accent,
                isOn: $state.memorySearchChats
            )
            Divider().background(Theme.separator)
            ToggleRow(
                systemImage: "square.stack.3d.up",
                title: "Generate memory from chats",
                subtitle: "Allow the assistant to generate lasting memory from your chats.",
                iconColor: Theme.accent,
                isOn: $state.memoryGenerateFromChats
            )
        }
    }

    private var importCard: some View {
        card {
            Button {
                showMemoryImport = true
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Import memory from other AI providers")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                        Text("Copy a prompt, paste the export from another AI, and add it to memory.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text("Start import")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceElevated, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
        }
    }

    private var entriesCard: some View {
        card {
            if userMemory.isEmpty {
                Text("No saved memories yet. Type a fact below or import from another AI.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                ForEach(UserMemoryStore.Category.displayOrder, id: \.self) { cat in
                    let items = userMemory.byCategory(cat)
                    if !items.isEmpty {
                        Text(cat.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                        ForEach(items) { entry in
                            Button {
                                memoryDetailID = entry.id
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(entry.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                        .frame(minWidth: 72, alignment: .leading)
                                    Text(entry.summary.isEmpty ? (entry.details.first ?? "No summary") : entry.summary)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(entry.relativeUpdated)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var draftCard: some View {
        card {
            HStack(spacing: 8) {
                TextField("My dog’s name is Beans", text: $memoryDraft, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit { submitMemoryDraft() }
                Button(action: submitMemoryDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(
                            memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Theme.textSecondary
                                : Theme.background
                        )
                        .frame(width: 34, height: 34)
                        .background(
                            memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Theme.surfaceElevated
                                : Theme.accent,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func submitMemoryDraft() {
        let text = memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        _ = userMemory.addFreeformFact(text)
        memoryDraft = ""
    }
}

// MARK: - Import / detail sheets

private struct MemoryDetailRoute: Identifiable, Hashable {
    let id: String
}

private struct MemoryImportSheet: View {
    var onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var paste = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    stepHeader(1, "Copy this prompt into a chat with your other AI provider")
                    ZStack(alignment: .topTrailing) {
                        Text(UserMemoryStore.importPrompt)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .padding(.trailing, 64)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        Button {
                            UIPasteboard.general.string = UserMemoryStore.importPrompt
                            copied = true
                        } label: {
                            Text(copied ? "Copied" : "Copy")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.surfaceElevated, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                    }

                    stepHeader(2, "Paste results below to add to memory")
                    TextEditor(text: $paste)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minHeight: 160)
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topLeading) {
                            if paste.isEmpty {
                                Text("Paste your memory details here")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(16)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Add to memory") {
                            onAdd(paste)
                            dismiss()
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Theme.surfaceElevated
                                : Theme.accent,
                            in: Capsule()
                        )
                        .disabled(paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Import memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .presentationDetents([.large, .medium])
        .presentationBackground(Theme.background)
    }

    private func stepHeader(_ n: Int, _ title: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .background(Theme.surfaceElevated, in: Circle())
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct MemoryEntryDetailSheet: View {
    let entryID: String
    @ObservedObject var store: UserMemoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var showDeleteConfirm = false

    private var entry: UserMemoryStore.Entry? {
        store.entry(id: entryID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let entry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Summary")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                            Text(entry.summary.isEmpty ? "No summary yet." : entry.summary)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)

                            Text("Details")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 4)
                            if entry.details.isEmpty {
                                Text("No details yet.")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textTertiary)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(entry.details, id: \.self) { line in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("•")
                                                .foregroundStyle(Theme.textSecondary)
                                            Text(line)
                                                .font(.system(size: 15))
                                                .foregroundStyle(Theme.textPrimary)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }

                    HStack(spacing: 8) {
                        TextField("Tell the assistant what to change or remove", text: $command, axis: .vertical)
                            .lineLimit(1...3)
                            .font(.system(size: 15))
                            .onSubmit { apply() }
                        Button(action: apply) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(
                                    command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? Theme.textSecondary
                                        : Theme.background
                                )
                                .frame(width: 34, height: 34)
                                .background(
                                    command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? Theme.surfaceElevated
                                        : Theme.accent,
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.surfaceElevated, in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                } else {
                    ContentUnavailableView("Memory deleted", systemImage: "trash")
                }
            }
            .background(Theme.background)
            .navigationTitle(entry?.title ?? "Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Memory")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .foregroundStyle(.red.opacity(0.9))
                }
            }
            .confirmationDialog(
                "Delete this memory?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    store.delete(id: entryID)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.large, .medium])
        .presentationBackground(Theme.background)
    }

    private func apply() {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        _ = store.applyEntryCommand(id: entryID, command: cmd)
        command = ""
    }
}
