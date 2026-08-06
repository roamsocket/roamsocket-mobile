import SwiftUI
import AnyProvCore

/// Detail view for a skill with "Add to Chat" functionality.
struct SkillDetailView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showCopied = false
    
    let skill: Skill
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    
                    if !skill.description.isEmpty {
                        section(title: "Description") {
                            Text(skill.description)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    
                    section(title: "Skill Content") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(skill.content)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                    }
                    
                    actionButtons
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle(skill.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: skill.category.icon)
                .font(.system(size: 32))
                .foregroundStyle(Theme.accent)
                .frame(width: 60, height: 60)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(skill.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    
                    if skill.source == .official {
                        Text("Official")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                
                Text(skill.category.rawValue)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            
            Spacer()
        }
    }
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                addToChat()
            } label: {
                Label("Add to Chat", systemImage: "message.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            
            Button {
                copyContent()
            } label: {
                Label(showCopied ? "Copied!" : "Copy Content", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }
    
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }
    
    private func addToChat() {
        // This would need to be connected to the chat system
        // For now, we'll just dismiss
        dismiss()
    }
    
    private func copyContent() {
        UIPasteboard.general.string = skill.content
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopied = false
        }
    }
}
