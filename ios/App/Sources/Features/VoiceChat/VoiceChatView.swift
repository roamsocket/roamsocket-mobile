import SwiftUI
import AnyProvCore

/// Full-screen live voice chat — dictation in, spoken model replies out.
/// Layout mirrors common voice-mode shells: idle sparkle + caption, large mic,
/// model pill, dismiss, and light top chrome.
struct VoiceChatView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var chatViewModel: ChatViewModel
    @StateObject private var viewModel = VoiceChatViewModel()

    var onOpenSidebar: (() -> Void)?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                Spacer(minLength: 0)

                centerStatus
                    .padding(.horizontal, 28)

                Spacer(minLength: 0)

                micButton
                    .padding(.bottom, 28)

                bottomChrome
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(state.appearance.colorScheme)
        .onAppear {
            viewModel.bind(chat: chatViewModel, state: state)
        }
        .onDisappear {
            viewModel.stopAll()
        }
        .sheet(isPresented: $viewModel.showModelPicker, onDismiss: {
            chatViewModel.persistSelectedModel()
        }) {
            ModelPickerSheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $viewModel.showSettings) {
            VoiceSettingsView()
                .environmentObject(state)
        }
        .sheet(isPresented: $viewModel.showProviderSettings) {
            AppSettingsView(initialFocus: .providers)
                .environmentObject(state)
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        // Hit-test only the controls — not the full-width strip — so the rest
        // of the screen stays free for mic / model / bottom close.
        HStack(spacing: 12) {
            Button {
                exitVoiceChat()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 44, height: 44)
                    .background(Theme.textPrimary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close voice chat")

            Spacer(minLength: 0)

            if onOpenSidebar != nil {
                Button {
                    viewModel.stopAll()
                    dismiss()
                    // Let the cover finish dismissing before opening the drawer.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        onOpenSidebar?()
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Theme.surfaceElevated.opacity(0.9), in: Circle())
                        .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open sidebar")
            }

            Button {
                viewModel.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated.opacity(0.9), in: Circle())
                    .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voice settings")
        }
    }

    private func exitVoiceChat() {
        viewModel.stopAll()
        dismiss()
    }

    private var centerStatus: some View {
        VStack(spacing: 18) {
            phaseIcon
                .frame(width: 56, height: 56)

            Text(viewModel.statusHeadline)
                .font(.system(size: 26, weight: .regular, design: .serif))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .minimumScaleFactor(0.75)
                .animation(.easeInOut(duration: 0.2), value: viewModel.statusHeadline)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch viewModel.phase {
        case .idle:
            Image(systemName: "sparkle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, options: .repeating.speed(0.35), isActive: true)
        case .listening:
            Image(systemName: "waveform")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: true)
        case .thinking:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Theme.accent)
                .scaleEffect(1.2)
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: true)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.yellow)
        }
    }

    private var micButton: some View {
        Button(action: { viewModel.micTapped() }) {
            ZStack {
                // Soft glow while active.
                if viewModel.isActive {
                    Circle()
                        .fill(Theme.accent.opacity(0.18))
                        .frame(width: 96, height: 96)
                        .blur(radius: 2)
                }
                Circle()
                    .fill(micFill)
                    .frame(width: 72, height: 72)
                    .overlay(
                        Circle()
                            .stroke(Theme.separator.opacity(0.6), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 16, y: 8)

                Image(systemName: micSymbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(micAccessibilityLabel)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isActive)
    }

    private var micFill: Color {
        switch viewModel.phase {
        case .listening: return Theme.accent.opacity(0.35)
        case .thinking, .speaking: return Theme.surfaceElevated
        case .error: return Theme.surfaceElevated
        case .idle: return Theme.surfaceElevated
        }
    }

    private var micSymbol: String {
        switch viewModel.phase {
        case .speaking: return "stop.fill"
        case .listening: return "mic.fill"
        case .thinking: return "ellipsis"
        case .error, .idle: return "mic"
        }
    }

    private var micAccessibilityLabel: String {
        switch viewModel.phase {
        case .idle, .error: return "Start voice chat"
        case .listening: return "Stop listening"
        case .thinking: return "Cancel"
        case .speaking: return "Stop speaking"
        }
    }

    private var bottomChrome: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                chatViewModel.showAddToChatSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated.opacity(0.95), in: Circle())
                    .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add to chat")

            Spacer(minLength: 8)

            ModelSelectorPill(
                modelDisplayName: viewModel.modelDisplayName,
                onPick: { viewModel.showModelPicker = true },
                onAddModel: { viewModel.showProviderSettings = true }
            )

            // Close lives in the top bar so it is never covered by bottom chrome.
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $chatViewModel.showAddToChatSheet) {
            AddToChatSheet(viewModel: chatViewModel) { _ in
                // Voice mode stays on chat path; coding session launch is not
                // started from this surface.
            }
            .environmentObject(state)
        }
    }
}
