import SwiftUI

/// Message actions context menu (Share, Add to project, Star, Rename, Delete)
struct MessageActionsSheet: View {
    let message: ChatMessage
    var onShare: () -> Void
    var onAddToProject: () -> Void
    var onStar: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Title
                Text("Plenty of Fish profile blurb")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                
                // Actions
                VStack(spacing: 0) {
                    actionRow(
                        systemImage: "square.and.arrow.up",
                        title: "Share",
                        color: Theme.textPrimary
                    ) {
                        onShare()
                        dismiss()
                    }
                    
                    Divider().background(Theme.separator).padding(.leading, 50)
                    
                    actionRow(
                        systemImage: "tray.full",
                        title: "Add to project",
                        color: Theme.textPrimary
                    ) {
                        onAddToProject()
                        dismiss()
                    }
                    
                    Divider().background(Theme.separator).padding(.leading, 50)
                    
                    actionRow(
                        systemImage: "star",
                        title: "Star",
                        color: Theme.textPrimary
                    ) {
                        onStar()
                        dismiss()
                    }
                    
                    Divider().background(Theme.separator).padding(.leading, 50)
                    
                    actionRow(
                        systemImage: "pencil",
                        title: "Rename",
                        color: Theme.textPrimary
                    ) {
                        onRename()
                        dismiss()
                    }
                    
                    Divider().background(Theme.separator).padding(.leading, 50)
                    
                    actionRow(
                        systemImage: "trash",
                        title: "Delete",
                        color: Color(hex: 0xFF453A)
                    ) {
                        onDelete()
                        dismiss()
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                
                Spacer()
            }
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }
    
    // MARK: - Action Row
    
    private func actionRow(systemImage: String, title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(color)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MessageActionsSheet(
        message: ChatMessage(role: .assistant, content: "Sample message"),
        onShare: {},
        onAddToProject: {},
        onStar: {},
        onRename: {},
        onDelete: {}
    )
}
