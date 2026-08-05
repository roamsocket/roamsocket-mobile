import SwiftUI

/// Main chat view, mimicking the Claude iOS UI:
///  * On a fresh / empty chat, shows a centered greeting like
///    "Clocking in for the evening shift." with a centered asterism glyph.
///  * Otherwise renders a vertically scrolling message list.
///  * The bottom composer holds a `+` button, a model pill, a mic, and a
///    gradient send button.
struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @EnvironmentObject var state: AppState
    var onOpenSidebar: () -> Void = {}

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                if isEffectivelyEmpty {
                    greeting
                } else {
                    messageList
                }
                composer
            }
        }
        .sheet(isPresented: $viewModel.showAddToChatSheet) {
            AddToChatSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showConnectorsView) {
            ConnectorsView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showThoughtProcess) {
            ThoughtProcessView(thoughtProcess: viewModel.currentThoughtProcess ?? "")
        }
    }

    /// True when there are no real user messages yet. The single welcome
    /// message that `ChatViewModel` seeds is treated as part of the empty
    /// state so we can show the centered greeting.
    private var isEffectivelyEmpty: Bool {
        viewModel.messages.allSatisfy { $0.role == .assistant } &&
        viewModel.messages.count <= 1
    }

    // MARK: - Greeting (empty state)

    private var greeting: some View {
        VStack(spacing: 18) {
            Spacer()
            AsterismGlyph()
                .frame(width: 56, height: 56)
            Text("Clocking in for the evening shift.")
                .font(.system(size: 26, weight: .regular, design: .serif))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        ChatMessageView(
                            message: message,
                            onCopy: { viewModel.copyMessage(message) },
                            onShare: { viewModel.shareMessage(message) },
                            onStar: { viewModel.starMessage(message) },
                            onDelete: { viewModel.deleteMessage(message) },
                            onRegenerate: { Task { await viewModel.regenerateResponse(for: message) } },
                            onThoughtProcess: {
                                viewModel.currentThoughtProcess = message.thoughtProcess
                                viewModel.showThoughtProcess = true
                            }
                        )
                        .id(message.id)
                    }

                    if viewModel.isProcessing {
                        ProcessingIndicator()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let lastMessage = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            composerSurface
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 8)
        .background(Theme.background)
    }

    private var composerSurface: some View {
        HStack(alignment: .center, spacing: 8) {
            // Plus: opens the AddToChat sheet
            Button(action: { viewModel.showAddToChatSheet = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .layoutPriority(2)

            // Model pill — inline with the field; truncated if needed.
            Button(action: {
                // Future: route into ModelPickerSheet.
            }) {
                HStack(spacing: 6) {
                    Text(modelPillTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surfaceElevated, in: Capsule())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)

            // Flexible text field with built-in placeholder.
            TextField("Chat with Claude", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.textPrimary)
                .frame(minHeight: 24, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            // Mic
            Button(action: {}) {
                Image(systemName: "mic")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .layoutPriority(2)

            // Send
            Button(action: {
                Task { await viewModel.sendMessage() }
            }) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(sendBackground, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .layoutPriority(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Theme.separator, lineWidth: 1)
        )
    }

    private var modelPillTitle: String {
        state.selectedModel?.displayName ?? "Sonnet 5 Medium"
    }

    private var sendBackground: some ShapeStyle {
        if viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AnyShapeStyle(Theme.surfaceElevated)
        } else {
            // Orange gradient like the screenshot.
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Theme.accent, Theme.accent.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}

/// Processing indicator shown while AI is generating.
struct ProcessingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
            Text("Thinking...")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The decorative asterism glyph shown on the empty chat (mimics the
/// orange burst in the screenshot).
struct AsterismGlyph: View {
    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 4, height: 22)
                    .offset(y: -16)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
            // Center dot
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
        }
        .frame(width: 56, height: 56)
        .compositingGroup()
    }
}

#Preview {
    ChatView()
}
