import SwiftUI
import MobileAICore

/// Form for adding a custom MCP server.
struct AddMCPServerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var description = ""
    @State private var command = ""
    @State private var argsText = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Server Details") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                
                Section("Command") {
                    TextField("Command (e.g., npx, node)", text: $command)
                        .textInputAutocapitalization(.never)
                    TextField("Arguments (one per line)", text: $argsText, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(3...6)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Add MCP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addServer()
                    }
                    .disabled(name.isEmpty || command.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func addServer() {
        let args = argsText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        let server = MCPServer(
            id: UUID().uuidString,
            name: name,
            description: description,
            command: command,
            args: args,
            isEnabled: true
        )
        
        state.mcpManager.addServer(server)
        dismiss()
    }
}
