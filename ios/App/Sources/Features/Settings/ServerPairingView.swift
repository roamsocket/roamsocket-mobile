import SwiftUI
import MobileAICore
#if canImport(UIKit)
import UIKit
#endif

/// Pair with a running desktop server by entering its address and pairing code
/// (shown in the server console / QR).
struct ServerPairingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var host = "http://localhost:4319"
    @State private var code = ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("Server address") {
                TextField("http://192.168.1.20:4319", text: $host)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
            }
            Section("Pairing code") {
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                Button("Pair", action: pair)
                    .disabled(busy || code.isEmpty || host.isEmpty)
                if busy { ProgressView() }
                if !status.isEmpty {
                    Text(status).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            Section {
                Text("Run the server with `npm start` in the desktop-server folder, then enter the pairing code it prints.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Pair server")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pair() {
        guard let endpoint = ServerClient.Endpoint(host: host) else {
            status = "Invalid address."
            return
        }
        busy = true
        status = "Pairing…"
        Task {
            do {
                let response = try await state.serverClient.pair(
                    endpoint: endpoint,
                    code: code,
                    deviceName: deviceName())
                state.serverEndpoint = endpoint
                state.serverToken = response.token
                state.serverName = response.serverName
                busy = false
                dismiss()
            } catch {
                status = error.localizedDescription
                busy = false
            }
        }
    }

    private func deviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return "Device"
        #endif
    }
}
