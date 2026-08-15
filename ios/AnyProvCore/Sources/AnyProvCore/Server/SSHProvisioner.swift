import Crypto
import Foundation
import NIO
import NIOSSH

#if canImport(Citadel)
    import Citadel
#endif

/// SSH auto-setup for a remote desktop server.
///
/// Used by the iOS app's *Pair server → Auto-setup over SSH* flow. The
/// provisioner opens a single SSH connection, runs a short detection +
/// install + start sequence, and watches the server's stdout for the
/// `__ROAMSOCKET_READY__` JSON line that the server prints when
/// `APC_PRINT_JSON=1` is set (see `desktop-server/src/index.ts`).
///
/// Supported auth: password, RSA / ED25519 private keys in OpenSSH
/// envelope format (`-----BEGIN OPENSSH PRIVATE KEY-----`). Other key
/// types are rejected with a clear error so users know to convert with
/// `ssh-keygen -p -m PEM`.
public enum SSHAuth: Sendable, Equatable {
    case password(String)
    case privateKey(pem: String, passphrase: String?)
}

public struct SSHProvisionConfig: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var auth: SSHAuth
    /// Shell command that installs `@roamsocket/server` on the remote.
    /// Default: `npm i -g @roamsocket/server` (npm-global install path).
    public var installCommand: String
    /// Hard ceiling for the whole flow (connect → install → start →
    /// parse). Default 240s; install steps on slow links can take a
    /// minute or two.
    public var timeoutSeconds: Int

    public init(
        host: String,
        port: Int = 22,
        username: String,
        auth: SSHAuth,
        installCommand: String = "npm i -g @roamsocket/server",
        timeoutSeconds: Int = 240
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.installCommand = installCommand
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct SSHProvisionResult: Sendable {
    public var pairingCode: String
    /// Tunnel URL printed by the server's `APC_PRINT_JSON=1` boot path.
    /// `nil` when no public tunnel was started (LAN-only pairing).
    public var publicURL: String?
    /// `http://<host>:<port>` derived from the JSON line, useful when
    /// the iOS device is on the same LAN as the SSH target.
    public var lanURL: String?
    public var serverName: String?
    public var serverVersion: String?
    /// Sanitized tail of the install + start logs, for the UI to show
    /// in the success / failure summary.
    public var installLog: String
}

public enum SSHProvisionError: Error, LocalizedError, Equatable {
    case authFailed(String)
    case unsupportedAuthKeyType(String)
    case unsupportedOS(String)
    case nodeNotFound
    case nodeTooOld(String)
    case installFailed(String)
    case readyPayloadNotFound(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case let .authFailed(m): return "SSH authentication failed: \(m)"
        case let .unsupportedAuthKeyType(t):
            return "Private key type \(t) is not supported. Convert with `ssh-keygen -p -m PEM -f <key>` or use a password."
        case let .unsupportedOS(s): return "Unsupported remote OS: \(s)"
        case .nodeNotFound: return "Node.js ≥20 was not found on the remote host. Install Node first (https://nodejs.org)."
        case let .nodeTooOld(v): return "Node.js \(v) is too old. Install Node 20 or newer."
        case let .installFailed(m): return "Install failed: \(m)"
        case let .readyPayloadNotFound(m):
            return "Server started but didn't emit a ready payload: \(m)"
        case .timedOut: return "Timed out before the server finished starting."
        }
    }
}

/// Drives a single end-to-end SSH auto-setup session. One instance per
/// flow; construct, call `provision(...)`, await the result.
public actor SSHProvisioner {
    public init() {}

    /// Run the full SSH auto-setup sequence.
    ///
    /// - Parameters:
    ///   - config: SSH credentials, install command, timeout.
    ///   - progress: Receives human-readable status updates suitable for
    ///     showing in a SwiftUI sheet ("Connecting…", "Installing…", etc.).
    public func provision(
        _ config: SSHProvisionConfig,
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> SSHProvisionResult {
        progress("Connecting to \(config.username)@\(config.host):\(config.port)…")
        let client = try await Self.connect(config)

        defer {
            // Best-effort close — we don't care if it throws.
            Task { try? await client.close() }
        }

        progress("Detecting remote OS…")
        let osDesc = try await Self.firstNonEmptyLine(
            client.executeCommand("uname -sm", mergeStreams: true)
        )
        guard !osDesc.isEmpty else {
            throw SSHProvisionError.unsupportedOS("(uname returned nothing)")
        }

        progress("Checking Node.js…")
        let nodeOutput = try await Self.firstNonEmptyLine(
            client.executeCommand("command -v node && node -v", mergeStreams: true)
        )
        guard !nodeOutput.isEmpty else {
            throw SSHProvisionError.nodeNotFound
        }
        try Self.assertNodeSupported(versionString: nodeOutput)

        progress("Installing server (\(config.installCommand))…")
        let installOutput = try await client.executeCommand(
            config.installCommand,
            mergeStreams: true,
            inShell: true
        )
        let installText = String(buffer: installOutput)
        // `executeCommand` throws `CommandFailed` on non-zero exit, so if
        // we get here the install succeeded. We still log the tail so the
        // UI can show "Installed foo@1.2.3" confirmation.
        let installTail = installText
            .split(separator: "\n")
            .suffix(40)
            .joined(separator: "\n")

        progress("Starting server and waiting for pairing code…")
        let ready = try await Self.collectReadyPayload(client: client)

        progress("Pairing ready.")
        let lanURL = "http://\(config.host):\(ready.port)"
        return SSHProvisionResult(
            pairingCode: ready.pairingCode,
            publicURL: ready.publicUrl,
            lanURL: lanURL,
            serverName: ready.serverName,
            serverVersion: ready.serverVersion,
            installLog: installTail
        )
    }

    // MARK: - internals

    private static func connect(_ config: SSHProvisionConfig) async throws -> SSHClient {
        // Citadel's `authenticationMethod` closure is non-throwing, so we
        // resolve the typed auth method up front (parsing the OpenSSH key
        // envelope if needed) and just hand the value back.
        let authMethod = try citadelAuth(for: config)
        let settings = SSHClientSettings(
            host: config.host,
            port: config.port,
            authenticationMethod: { authMethod },
            hostKeyValidator: .acceptAnything()
        )
        return try await SSHClient.connect(to: settings)
    }

    private static func citadelAuth(for config: SSHProvisionConfig) throws -> SSHAuthenticationMethod {
        switch config.auth {
        case let .password(pw):
            return .passwordBased(username: config.username, password: pw)
        case let .privateKey(pem, passphrase):
            switch try SSHPrivateKeyParser.parse(pem: pem, passphrase: passphrase) {
            case let .ed25519(key):
                return .ed25519(username: config.username, privateKey: key)
            }
        }
    }

    private static func firstNonEmptyLine(_ buffer: ByteBuffer) -> String {
        let text = String(buffer: buffer)
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                return line
            }
        }
        return ""
    }

    private static func assertNodeSupported(versionString: String) throws {
        // The command outputs "v20.10.0" (possibly with the install path
        // on a second line because of the `&&` shell short-circuit). Pull
        // the first "vX.Y.Z" token, ignore everything else.
        let cleaned = versionString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "")
        let majorToken = cleaned.split(separator: ".").first.map(String.init) ?? "0"
        let major = Int(majorToken) ?? 0
        if major < 20 {
            throw SSHProvisionError.nodeTooOld("v\(majorToken)")
        }
    }

    private static let readySentinel = "__ROAMSOCKET_READY__"

    private struct ReadyPayload: Decodable {
        let port: Int
        let host: String
        let pairingCode: String
        let serverName: String?
        let serverVersion: String?
        let publicUrl: String?
    }

    /// Stream the server start command (with `APC_PRINT_JSON` + `APC_AUTO_TUNNEL`
    /// env vars) and wait for the sentinel line. The Citadel stream keeps
    /// producing until the server exits; we close the client once we see
    /// the payload.
    private static func collectReadyPayload(client: SSHClient) async throws -> ReadyPayload {
        let stream = try await client.executeCommandStream(
            "roamsocket --serve-only",
            environment: [
                SSHChannelRequestEvent.EnvironmentRequest(
                    wantReply: false,
                    name: "APC_PRINT_JSON",
                    value: "1"
                ),
                SSHChannelRequestEvent.EnvironmentRequest(
                    wantReply: false,
                    name: "APC_AUTO_TUNNEL",
                    value: "1"
                ),
            ]
        )
        var stdoutBuffer = ""
        var stderrBuffer = ""
        for try await chunk in stream {
            switch chunk {
            case let .stdout(buf):
                if let s = buf.getString(at: buf.readerIndex, length: buf.readableBytes) {
                    stdoutBuffer += s
                }
            case let .stderr(buf):
                if let s = buf.getString(at: buf.readerIndex, length: buf.readableBytes) {
                    stderrBuffer += s
                }
            }
            if let payload = extractReadyPayload(from: stdoutBuffer) {
                return payload
            }
        }
        throw SSHProvisionError.readyPayloadNotFound(
            "stream ended. stderr tail: \(String(stderrBuffer.suffix(400)))"
        )
    }

    private static func extractReadyPayload(from buffer: String) -> ReadyPayload? {
        guard let range = buffer.range(of: readySentinel) else { return nil }
        let after = buffer[range.upperBound...]
        let scanner = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let nl = scanner.firstIndex(of: "\n") else {
            return nil
        }
        let jsonSlice = scanner[scanner.startIndex ..< nl]
        guard let data = String(jsonSlice).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReadyPayload.self, from: data)
    }
}
