import SwiftUI

/// Thought process modal showing the AI's reasoning
struct ThoughtProcessView: View {
    let thoughtProcess: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Text("Thought process")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    
                    Spacer()
                    
                    // Spacer for symmetry
                    Color.clear
                        .frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 16)
                
                // Content
                ScrollView {
                    Text(thoughtProcess)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
                
                Spacer()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    ThoughtProcessView(
        thoughtProcess: "They've confirmed this is for a Plenty of Fish dating profile. I should ask a few targeted questions to help write an effective blurb without overwhelming them with too many prompts. I'll use the input elicitation tool since this is about personal preferences. I have some context from memory—Julian founded kind365 and is based in Colorado with gaming interests—but I should check what tone they want and whether they'd like to include any of those details, since a dating profile is personal and might not need work-related information."
    )
}
