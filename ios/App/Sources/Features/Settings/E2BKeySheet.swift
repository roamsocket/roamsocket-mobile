import SwiftUI
import AnyProvCore

/// Reusable "paste your e2b.dev API key" sheet. Lifted out of
/// `AppSettingsView` so the Sandboxes empty state, the Code home
/// empty state, and any future deep link can present the same UI
/// with the same validation + verification flow.
///
/// Reads the key from `state.e2bKeyStore` (a single source of
/// truth on the device) and writes back through it. The view is
/// stateless about the key's persistence — that's `E2BKeyStore`'s
/// job.
struct E2BKeySheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var draft: String = ""
    /// Inline validation error from `E2BKeyStore.validate`.
    @State private var validationError: String?
    /// Result of the post-save `DirectE2BClient.verifyKey` ping.
    @State private var verification: E2BVerificationStatus = .idle

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidFormat: Bool {
        if case .valid = E2BKeyStore.validate(trimmedDraft) { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your e2b.dev key")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Paste an e2b.dev API key so the phone can spin up sandboxes on its own. The key is held on this device only and is used to call e2b.dev directly — nothing is sent anywhere else.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    SecureField("e2b_…", text: $draft)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(12)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                        .onChange(of: draft) { _, newValue in
                            // Live format validation. Only show the
                            // error once the user has typed
                            // something — the placeholder
                            // "e2b_…" shouldn't count as an error.
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            switch E2BKeyStore.validate(trimmed) {
                            case .missing, .valid:
                                validationError = nil
                            case let .invalid(reason):
                                validationError = reason
                            }
                            // A new draft invalidates any prior
                            // verification result. The "Verifying…"
                            // state is a transient that's about to
                            // land anyway; resetting it is harmless
                            // and avoids showing a "Verifying…" badge
                            // for a draft the user hasn't saved.
                            verification = .idle
                        }
                    if let validationError {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                    verificationBadge
                    HStack {
                        if state.e2bKeyStore.hasKey {
                            Button(role: .destructive) {
                                state.e2bKeyStore.set(nil)
                                verification = .idle
                            } label: {
                                Text("Clear")
                            }
                        }
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(Theme.textSecondary)
                        Button("Save") { saveAndVerify() }
                            .foregroundStyle(Theme.accent)
                            .disabled(!isValidFormat)
                    }
                    // Help the user who landed here without an
                    // e2b.dev account. Deep link to the keys page.
                    Button {
                        if let url = URL(string: "https://e2b.dev/dashboard?tab=keys") {
                            openURL(url)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 12))
                            Text("Get an e2b.dev API key")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("E2B API key")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var verificationBadge: some View {
        switch verification {
        case .idle:
            EmptyView()
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Verifying with e2b.dev…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .verified:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.selection)
                Text("Verified — your key works.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.selection)
            }
        case let .failed(message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.seal.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    /// Save the key, then call `DirectE2BClient.verifyKey()` to
    /// confirm it actually works. The status badge updates when the
    /// round-trip completes.
    private func saveAndVerify() {
        guard isValidFormat else { return }
        let key = trimmedDraft
        state.e2bKeyStore.set(key)
        verification = .verifying
        Task { [key] in
            let result = await Self.verify(key: key)
            await MainActor.run { verification = result }
        }
    }

    /// Stand-alone wrapper that runs the verification on a detached
    /// task and converts any error into a user-readable status. Kept
    /// separate from the view so it can be unit-tested if needed.
    private static func verify(key: String) async -> E2BVerificationStatus {
        let client = DirectE2BClient(apiKey: key)
        do {
            let status = try await client.verifyKey()
            return (200..<300).contains(status) ? .verified : .failed("e2b.dev returned HTTP \(status).")
        } catch let error as DirectE2BError {
            switch error {
            case .noApiKey: return .failed("Key is empty.")
            case let .http(status, body):
                let snippet = body.isEmpty ? "" : " — \(body.prefix(80))"
                return .failed("e2b.dev rejected the key (HTTP \(status))\(snippet)")
            case let .transport(msg): return .failed("Network error: \(msg)")
            case let .decoding(msg): return .failed("Couldn't decode the response: \(msg)")
            case let .stream(msg): return .failed("Stream error: \(msg)")
            }
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// One-shot verification status for the e2b key. Mirrors the
/// state machine in `E2BKeyStore.validate` but covers the
/// network round-trip too.
enum E2BVerificationStatus: Equatable {
    case idle
    case verifying
    case verified
    case failed(String)
}
