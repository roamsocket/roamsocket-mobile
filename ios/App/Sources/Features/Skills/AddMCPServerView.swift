import SwiftUI
import MobileAICore

/// Form for adding a custom connector (formerly "MCP server"). The form
/// supports two auth modes: `Environment variables` (for `stdio` connectors
/// that read tokens from their process env) and `Bearer token` (for
/// `http`/`sse` connectors that need an `Authorization` header).
struct AddConnectorView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var transport: Transport = .stdio
    @State private var command = ""
    @State private var argsText = ""
    @State private var envText = ""   // KEY=value per line
    @State private var bearerToken = ""
    @State private var url = ""
    @State private var error: String?

    enum Transport: String, CaseIterable, Identifiable {
        case stdio = "stdio"
        case http = "http"
        case sse = "sse"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .stdio: return "stdio (run a command)"
            case .http: return "http (POST /mcp)"
            case .sse: return "sse (Server-Sent Events)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connector") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("Transport") {
                    Picker("Type", selection: $transport) {
                        ForEach(Transport.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                }

                if transport == .stdio {
                    Section("Command") {
                        TextField("Command (e.g., npx, node)", text: $command)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Arguments (one per line)", text: $argsText, axis: .vertical)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(3...6)
                    }
                } else {
                    Section("Endpoint") {
                        TextField("https://mcp.example.com/sse", text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }

                Section {
                    if transport == .stdio {
                        TextField("Env (KEY=value, one per line)", text: $envText, axis: .vertical)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(3...8)
                    } else {
                        SecureField("Bearer token (optional)", text: $bearerToken)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text(transport == .stdio
                         ? "Env vars are passed to the connector process. Use this for tokens, API keys, and project IDs the connector needs."
                         : "Bearer token is sent as `Authorization: Bearer …`. Leave blank for unauthenticated endpoints.")
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Add connector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .disabled(!isValid)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var isValid: Bool {
        guard !name.isEmpty else { return false }
        switch transport {
        case .stdio: return !command.isEmpty
        case .http, .sse: return !url.isEmpty && URL(string: url) != nil
        }
    }

    private func save() {
        let args = argsText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let env: [String: String] = transport == .stdio
            ? EnvironmentConfig.parseEnv(envText)
            : (bearerToken.isEmpty ? [:] : ["Authorization": "Bearer \(bearerToken)"])

        // For non-stdio, the URL travels through `env` under a synthetic key
        // so the desktop can construct the actual fetch request.
        var finalEnv = env
        if transport != .stdio {
            finalEnv["CMAI_CONNECTOR_URL"] = url
            finalEnv["CMAI_CONNECTOR_TRANSPORT"] = transport.rawValue
        }

        let server = MCPServer(
            id: UUID().uuidString,
            name: name,
            description: description,
            command: transport == .stdio ? command : "",
            args: transport == .stdio ? args : [],
            env: finalEnv,
            isEnabled: true
        )

        Task {
            try? await state.skillsMCPClient.upsertMCPServer(server, over: state.serverClient)
        }
        dismiss()
    }
}
