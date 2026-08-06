import SwiftUI
import AnyProvCore

/// "New cloud environment" form (screenshots 3 + 4):
/// name, network-access picker with the four labelled cards, an allowed-domains
/// editor for the Custom tier, and `.env`-format variables. The configured
/// network policy and env vars are sent to the desktop with `create_session`,
/// so the agent loop knows what it can do in this environment.
struct NewEnvironmentView: View {
    @Environment(\.dismiss) private var dismiss
    var onCreate: (EnvironmentConfig) -> Void

    @State private var name: String = ""
    @State private var networkAccess: NetworkAccess = .trusted
    @State private var customDomains: String = ""
    @State private var envText: String = ""
    @State private var showNetworkSheet = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case name, env, domains }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        nameField
                        networkField
                        if networkAccess == .custom {
                            customDomainsField
                        }
                        envField
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 120)
                }
                .scrollDismissesKeyboard(.interactively)
            }

            VStack {
                Spacer()
                createButton
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showNetworkSheet) {
            NetworkAccessSheet(selection: $networkAccess)
        }
        .onAppear { focused = .name }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("New cloud environment")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Name")
            TextField("", text: $name, prompt: Text("Default").foregroundColor(Theme.textTertiary))
                .focused($focused, equals: .name)
                .submitLabel(.next)
                .onSubmit { focused = .env }
                .textInputAutocapitalization(.never)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Network access

    private var networkField: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Network access")
            Button { showNetworkSheet = true } label: {
                HStack {
                    Text(networkAccess.displayName)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
    }

    private var customDomainsField: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Allowed domains")
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.field)
                if customDomains.isEmpty {
                    Text("api.github.com\npypi.org")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $customDomains)
                    .focused($focused, equals: .domains)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(minHeight: 120)
            Text("One host per line. Subdomains match automatically.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Environment variables

    private var envField: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Environment variables")
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.field)
                if envText.isEmpty {
                    Text("API_KEY=hunter2")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $envText)
                    .focused($focused, equals: .env)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(minHeight: 160)
            HStack(spacing: 4) {
                Text("In")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                Text(".env")
                    .font(.system(size: 14, design: .monospaced))
                    .underline()
                    .foregroundStyle(Theme.textTertiary)
                Text("format.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - Create button

    private var createButton: some View {
        Button(action: create) {
            Text("Create environment")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(canSubmit ? .black : Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(canSubmit ? Theme.textPrimary : Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [Theme.background.opacity(0), Theme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
    }

    private func create() {
        guard canSubmit else { return }
        let domains = customDomains
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let env = EnvironmentConfig(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            networkAccess: networkAccess,
            allowedDomains: networkAccess == .custom ? domains : [],
            variables: EnvironmentConfig.parseEnv(envText)
        )
        onCreate(env)
        dismiss()
    }
}

/// Popover sheet with the four network-access cards (screenshot 3).
struct NetworkAccessSheet: View {
    @Binding var selection: NetworkAccess
    @Environment(\.dismiss) private var dismiss

    private let options: [(NetworkAccess, String, String)] = [
        (.none, "No network access", "Blocks internet access for maximum security."),
        (.trusted, "Trusted network access", "Downloads packages from verified sources."),
        (.limited, "Full network access", "Unrestricted internet access for maximum flexibility."),
        (.custom, "Custom", "Create a list of allowed domains."),
    ]

    var body: some View {
        SheetScaffold(title: "Network access", trailing: nil, onClose: { dismiss() }) {
            VStack(spacing: 14) {
                ForEach(options, id: \.0) { entry in
                    Button {
                        selection = entry.0
                        dismiss()
                    } label: {
                        networkCard(
                            title: entry.1,
                            subtitle: entry.2,
                            isSelected: selection == entry.0
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            Spacer()
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
    }

    private func networkCard(title: String, subtitle: String, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isSelected ? Theme.selection : Color.clear, lineWidth: 2)
        )
    }
}
