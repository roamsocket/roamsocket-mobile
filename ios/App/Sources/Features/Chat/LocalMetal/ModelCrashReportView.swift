import SwiftUI
import AnyProvCore
#if canImport(UIKit)
import UIKit
#endif

/// Launch-time prompt shown when an on-device Metal model crashed during a
/// previous session. Tells the user which model crashed, offers the crash log
/// to copy, and asks whether they want to delete the model from disk.
///
/// Dismissal (any of the buttons or swipe-down) resolves the report in the
/// store so it is not re-asked on every launch.
struct ModelCrashReportView: View {
    let record: LocalMetalCrashRecord

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var didCopyLog = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                header
                logBox
                if let deleteError {
                    Text(deleteError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Model Crashed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Not now") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isDeleting)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text(record.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
            }
            Text("This on-device model crashed during your last use. Copy the crash log to share it, or delete the model to free disk space and re-download it later.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Scrollable, selectable copy of the crash log.
    private var logBox: some View {
        ScrollView {
            Text(record.logText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxHeight: 220)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.separator, lineWidth: 1)
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button(action: copyLog) {
                Label(didCopyLog ? "Copied" : "Copy Logs",
                      systemImage: didCopyLog ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(didCopyLog)

            Button(action: deleteModel) {
                if isDeleting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Delete Model", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isDeleting)
        }
        .controlSize(.large)
    }

    // MARK: - Actions

    private func copyLog() {
        guard !record.logText.isEmpty else { return }
        UIPasteboard.general.string = record.logText
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.15)) {
            didCopyLog = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if didCopyLog {
                withAnimation(.easeOut(duration: 0.15)) {
                    didCopyLog = false
                }
            }
        }
    }

    private func deleteModel() {
        guard !isDeleting else { return }
        isDeleting = true
        deleteError = nil
        let model = AIModel(
            provider: .localMetal,
            modelID: record.modelID,
            displayName: record.displayName
        )
        Task { @MainActor in
            do {
                try await state.removeModelFromPicker(model)
                dismiss()
            } catch {
                isDeleting = false
                deleteError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
