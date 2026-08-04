import SwiftUI

/// Add to Chat sheet with options for Camera, Files, Project, Tool Access, Skills, and Connectors
struct AddToChatSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        SheetScaffold(
            title: "Add to Chat",
            trailing: AnyView(
                Button("All photos") {}
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            ),
            onClose: { dismiss() }
        ) {
            ScrollView {
                VStack(spacing: 0) {
                    // Camera and recent photos row
                    cameraAndPhotosRow
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    
                    // Options section
                    optionsSection
                        .padding(.top, 16)
                    
                    // Skills toggles section
                    skillsSection
                        .padding(.top, 16)
                    
                    // Connectors row
                    connectorsRow
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                }
            }
        }
        .presentationDetents([.large])
    }
    
    // MARK: - Camera and Photos
    
    private var cameraAndPhotosRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // Camera button
                Button(action: {
                    // Open camera
                }) {
                    VStack(spacing: 8) {
                        Image(systemName: "camera")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Camera")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .frame(width: 120, height: 120)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                }
                .buttonStyle(.plain)
                
                // Recent photo thumbnails (placeholder)
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .fill(Theme.surfaceElevated)
                        .frame(width: 120, height: 120)
                        .overlay {
                            Text("Photo \(i + 1)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                }
            }
        }
    }
    
    // MARK: - Options Section
    
    private var optionsSection: some View {
        VStack(spacing: 0) {
            // Add files
            optionRow(
                systemImage: "doc.badge.plus",
                title: "Add files"
            ) {
                // Open file picker
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
        Button(action: { viewModel.showConnectorsView = true }) {
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
