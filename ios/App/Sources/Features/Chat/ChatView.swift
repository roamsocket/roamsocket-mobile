import SwiftUI

/// Main chat view with message list and composer
struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                chatHeader
                
                // Message list
                messageList
                
                // Composer
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
        .task {
            // Initialize MCP client
            // await viewModel.mcpClient.connect(serverURL: URL(string: "https://mcp.example.com")!)
        }
    }
    
    // MARK: - Header
    
    private var chatHeader: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text("Chat")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            
            Spacer()
            
            Button(action: { viewModel.showAddToChatSheet = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.background)
    }
    
    // MARK: - Message List
    
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
        VStack(spacing: 0) {
            Divider()
                .background(Theme.separator)
            
            HStack(spacing: 12) {
                // Add button
                Button(action: { viewModel.showAddToChatSheet = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                
                // Text input
                TextField("Reply to Claude", text: $viewModel.inputText, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
                
                // Send button
                Button(action: {
                    Task { await viewModel.sendMessage() }
                }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Theme.surfaceElevated
                            : Theme.accent,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            // Model selector pill
            HStack {
                Spacer()
                Pill(title: "Sonnet 5 Medium", systemImage: "sparkles") {
                    // Show model picker
                }
                .padding(.trailing, 16)
                .padding(.bottom, 8)
            }
        }
        .background(Theme.background)
    }
}

/// Processing indicator shown while AI is generating
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

#Preview {
    ChatView()
}
