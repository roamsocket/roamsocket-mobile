import SwiftUI

/// Add to Chat sheet with options for Files, Project, Tool Access,
/// Skills, and Connectors.
struct AddToChatSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    /// Optional handler fired when the user picks "Start coding session".
    /// The host view does the actual session creation (because it owns the
    /// `sessionConfig` state for the fullScreenCover).
    var onStartCodingSession: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(
            title: "Add to Chat",
            trailing: AnyView(EmptyView()),
            onClose: { dismiss() }
        ) {
            ScrollView {
                VStack(spacing: 0) {
                    optionsSection
                        .padding(.top, 16)

                    skillsSection
                        .padding(.top, 16)

                    connectorsRow
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                }
            }
        }
        .presentationDetents([.large])
        .fileImporter(
            isPresented: $viewModel.showFilePicker,
            allowedContentTypes: [.item]
        ) { result in
            if case .success(let url) = result {
                viewModel.attachedFileURLs.append(url)
            }
        }
    }

    // MARK: - Options Section

    private var optionsSection: some View {
        VStack(spacing: 0) {
            // Start a coding session — routes through the host view, which
            // owns the fullScreenCover state.
            optionRow(
                systemImage: "chevron.left.forwardslash.chevron.right",
                title: "Start coding session"
            ) {
                let task = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                dismiss()
                if !task.isEmpty {
                    // Small delay so the sheet finishes dismissing before the
                    // cover presents — avoids the iOS sheet/cover z-fight.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        onStartCodingSession?(task)
                    }
                } else {
                    onStartCodingSession?("Help me with this repo")
                }
            }

            Divider().background(Theme.separator).padding(.leading, 50)

            // Add files
            optionRow(
                systemImage: "doc.badge.plus",
                title: "Add files"
            ) {
                viewModel.showFilePicker = true
            }

            Divider().background(Theme.separator).padding(.leading, 50)
            
            // Add to project
            HStack(spacing: 14) {
                Image(systemName: "tray.full")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                
                Text("Add to project")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                
                Spacer()
                
                Text(viewModel.currentProject ?? "None")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            
            Divider().background(Theme.separator).padding(.leading, 50)
            
            // Tool access
            HStack(spacing: 14) {
                Image(systemName: "briefcase")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                
                Text("Tool access")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                
                Spacer()
                
                Text(viewModel.toolAccess.rawValue)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .padding(.horizontal, 16)
    }
    
    // MARK: - Skills Section
    
    private var skillsSection: some View {
        VStack(spacing: 0) {
            // Research toggle
            skillToggleRow(
                systemImage: "magnifyingglass",
                title: "Research",
                isOn: $viewModel.researchEnabled
            )
            
            Divider().background(Theme.separator).padding(.leading, 50)
            
            // Web search toggle
            skillToggleRow(
                systemImage: "globe",
                title: "Web search",
                isOn: $viewModel.webSearchEnabled
            )
            
            Divider().background(Theme.separator).padding(.leading, 50)
            
            // Health toggle
            HStack(spacing: 14) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.pink)
                    .frame(width: 32, height: 32)
                
                Text("Health")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                
                Text("Beta")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.surfaceElevated, in: Capsule())
                
                Spacer()
                
                Toggle("", isOn: $viewModel.healthEnabled)
                    .labelsHidden()
                    .tint(Theme.selection)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .padding(.horizontal, 16)
    }
    
    // MARK: - Connectors Row

    private var connectorsRow: some View {
        Button(action: {
            // The connectors view is presented from ChatView as a sibling
            // sheet; presenting a sheet from inside a sheet on iOS is
            // unreliable, so we dismiss first and ask the host to open
            // the connectors sheet on the next runloop tick.
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                viewModel.showConnectorsView = true
            }
        }) {
            HStack(spacing: 14) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                
                Text("Connectors")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
    
    // MARK: - Helper Views
    
    private func optionRow(systemImage: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func skillToggleRow(systemImage: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
            
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(Theme.textPrimary)
            
            Spacer()
            
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.selection)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

#Preview {
    AddToChatSheet(viewModel: ChatViewModel())
}
