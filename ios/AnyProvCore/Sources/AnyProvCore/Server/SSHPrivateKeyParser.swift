import Crypto
import Foundation

/// Parses OpenSSH-format private keys (`-----BEGIN OPENSSH PRIVATE KEY-----`)
/// into the typed key values Citadel's `SSHAuthenticationMethod` wants.
///
/// **ED25519 only** for now (the modern default — every new key since
/// OpenSSH 6.5 / 2014). RSA private keys would need raw BIGNUM access
/// via BoringSSL, which isn't reachable from this layer; users on RSA
/// can re-key with `ssh-keygen -t ed25519`.
///
/// **Unencrypted keys only** (ciphername/kdfname both `none`). To strip
/// a passphrase: `ssh-keygen -p -m PEM -f ~/.ssh/id_ed25519`.
enum SSHPrivateKeyParser {
    enum ParsedKey {
        case ed25519(Curve25519.Signing.PrivateKey)
    }

    enum ParseError: Error, LocalizedError, Equatable {
        case invalidFormat(String)
        case unsupportedKeyType(String)
        case unsupportedCipher(String)
        case unsupportedKDF(String)
        case malformedKey(String)

        var errorDescription: String? {
            switch self {
            case let .invalidFormat(s): return "Key is not in OpenSSH envelope format: \(s)"
            case let .unsupportedKeyType(t):
                return "Key type \(t) isn't supported (ED25519 only — convert with `ssh-keygen -t ed25519`)."
            case let .unsupportedCipher(c):
                return "Cipher \(c) isn't supported. Remove the passphrase with `ssh-keygen -p -m PEM -f <key>`."
            case let .unsupportedKDF(k): return "KDF \(k) isn't supported."
            case let .malformedKey(s): return "Key is malformed: \(s)"
            }
        }
    }

    static func parse(pem: String, passphrase: String?) throws -> ParsedKey {
        let body = pem
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "")
        guard body.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
              body.hasSuffix("-----END OPENSSH PRIVATE KEY-----")
        else {
            throw ParseError.invalidFormat("missing OpenSSH envelope markers")
        }
        let innerStart = body.index(body.startIndex, offsetBy: "-----BEGIN OPENSSH PRIVATE KEY-----".count)
        let innerEnd = body.index(body.endIndex, offsetBy: -"-----END OPENSSH PRIVATE KEY-----".count)
        let base64 = String(body[innerStart ..< innerEnd])
        guard let raw = Data(base64Encoded: base64) else {
            throw ParseError.invalidFormat("base64 payload did not decode")
        }

        var cursor = Cursor(data: raw)
        guard try cursor.readBytes(count: "openssh-key-v1\0".utf8.count) == Data("openssh-key-v1\0".utf8) else {
            throw ParseError.invalidFormat("missing openssh-key-v1 magic")
        }
        let cipherName = try cursor.readString()
        let kdfName = try cursor.readString()
        _ = try cursor.readString() // kdf options (unused for none/none)
        if cipherName != "none" {
            throw ParseError.unsupportedCipher(cipherName)
        }
        if kdfName != "none" {
            throw ParseError.unsupportedKDF(kdfName)
        }
        if let passphrase, !passphrase.isEmpty {
            throw ParseError.unsupportedCipher("passphrase supplied but encrypted keys aren't supported")
        }
        let numKeys: UInt32 = try cursor.readUInt32()
        guard numKeys == 1 else { throw ParseError.malformedKey("multiple keys not supported") }
        _ = try cursor.readString() // public key blob

        // Private blob has the same wire format; build a fresh cursor.
        let privateBytes = try cursor.readString()
        var priv = Cursor(data: Data(privateBytes.utf8))

        let checkA: UInt32 = try priv.readUInt32()
        let checkB: UInt32 = try priv.readUInt32()
        guard checkA == checkB else { throw ParseError.malformedKey("checkint mismatch") }

        let keyType = try priv.readString()
        switch keyType {
        case "ssh-ed25519":
            return try .ed25519(parseEd25519(cursor: &priv))
        default:
            throw ParseError.unsupportedKeyType(keyType)
        }
    }

    // MARK: - ED25519

    /// OpenSSH ED25519 private blob layout:
    ///   string "ssh-ed25519"
    ///   string public_key  (32 bytes)
    ///   string private_key (64 bytes = pub || seed)
    ///   string comment
    private static func parseEd25519(cursor: inout Cursor) throws -> Curve25519.Signing.PrivateKey {
        let publicKey = try cursor.readBytes()
        let privateKey = try cursor.readBytes()
        guard publicKey.count == 32 else {
            throw ParseError.malformedKey("ed25519 public key must be 32 bytes, got \(publicKey.count)")
        }
        guard privateKey.count == 64 else {
            throw ParseError.malformedKey("ed25519 private key blob must be 64 bytes, got \(privateKey.count)")
        }
        // OpenSSH stores the private blob as: pub (32) || seed (32).
        // Apple Crypto's `rawRepresentation` expects just the 32-byte seed.
        let seed = privateKey.prefix(32)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    // MARK: - Cursor

    /// Stateful cursor over the SSH envelope bytes. Each helper advances
    /// on success; throws on truncation. Marked `private` to the file
    /// because the only callers live here.
    private struct Cursor {
        private var data: Data

        init(data: Data) {
            self.data = data
        }

        /// Read exactly `count` bytes and return them.
        mutating func readBytes(count: Int? = nil) throws -> Data {
            let n = count ?? data.count
            guard data.count >= n else {
                throw ParseError.malformedKey("truncated (needed \(n), have \(data.count))")
            }
            let prefix = data.prefix(n)
            data.removeFirst(n)
            return prefix
        }

        mutating func readUInt32() throws -> UInt32 {
            guard data.count >= 4 else { throw ParseError.malformedKey("truncated uint32") }
            let value = UInt32(data[0]) << 24
                | UInt32(data[1]) << 16
                | UInt32(data[2]) << 8
                | UInt32(data[3])
            data.removeFirst(4)
            return value
        }

        /// Read an SSH length-prefixed UTF-8 string. The base parser uses
        /// the raw `Data` view (see `readLengthPrefixedData`) for binary
        /// blobs; this is the convenience wrapper for type strings.
        mutating func readString() throws -> String {
            let bytes = try readLengthPrefixedData()
            return String(data: bytes, encoding: .utf8) ?? ""
        }

        /// Read an SSH length-prefixed byte blob (used for public/private
        /// key material). Returns the inner Data; the 4-byte length header
        /// is consumed.
        mutating func readLengthPrefixedData() throws -> Data {
            let len = try readUInt32()
            guard data.count >= Int(len) else {
                throw ParseError.malformedKey("truncated string (needed \(len), have \(data.count))")
            }
            let slice = data.prefix(Int(len))
            data.removeFirst(Int(len))
            return slice
        }
    }
}
