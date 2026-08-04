import SwiftUI
import MobileAICore

/// The "New cloud environment" form (IMG_0990): name, network access, and
/// `.env`-format variables.
struct NewEnvironmentView: View {
    @Environment(\.dismiss) private var dismiss
    var onCreate: (EnvironmentConfig) -> Void

    @State private var name = ""
    @State private var networkAccess: NetworkAccess = .trusted
    @State private var envText = ""

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        field(label: "Name") {
                            TextField("", text: $name, prompt: Text("Default").foregroundColor(Theme.textTertiary))
                                .textInputAutocapitalization(.never)
                                .foregroundStyle(Theme.textPrimary)
                                .padding(16)
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: 16))
                        }

                        field(label: "Network access") {
                            Menu {
                                ForEach(NetworkAccess.allCases, id: \.self) { access in
                                    Button(access.displayName) { networkAccess = access }
                                }
                            } label: {
                                HStack {
                                    Text(networkAccess.displayName)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .padding(16)
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: 16))
                            }
                        }

                        field(label: "Environment variables") {
                            VStack(alignment: .leading, spacing: 8) {
                                TextEditor(text: $envText)
                                    .font(.system(size: 16, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 160)
                                    .padding(12)
                                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(alignment: .topLeading) {
                                        if envText.isEmpty {
                                            Text("API_KEY=hunter2")
                                                .font(.system(size: 16, design: .monospaced))
                                                .foregroundStyle(Theme.textTertiary)
                                                .padding(20)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                Text("In .env format.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    .padding(20)
                }

                Button(action: create) {
                    Text("Create environment")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(name.isEmpty ? Theme.textTertiary : .black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(name.isEmpty ? Theme.surfaceElevated : Theme.textPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(name.isEmpty)
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

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
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func create() {
        let env = EnvironmentConfig(
            name: name.trimmingCharacters(in: .whitespaces),
            networkAccess: networkAccess,
            variables: EnvironmentConfig.parseEnv(envText)
        )
        onCreate(env)
        dismiss()
    }
}
