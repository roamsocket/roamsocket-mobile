/**
 * Minimal macOS CLI for Apple Foundation Models (Apple Intelligence).
 *
 * Input (stdin JSON):
 *   { "system": "...", "user": "...", "maxTokens": 48 }
 * Output (stdout JSON line):
 *   { "ok": true, "text": "..." } | { "ok": false, "error": "..." }
 *
 * Build (macOS 26+ SDK):
 *   swiftc -O -o apc-foundation-cli apc-foundation-cli.swift
 *
 * CodeSocket Electron spawns this for Lightweight Tasks on Apple Silicon Macs.
 */
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct Request: Codable {
    var system: String?
    var user: String
    var maxTokens: Int?
}

struct Response: Codable {
    var ok: Bool
    var text: String?
    var error: String?
}

func writeJSON(_ response: Response) {
    let enc = JSONEncoder()
    if let data = try? enc.encode(response),
       let line = String(data: data, encoding: .utf8) {
        print(line)
    } else {
        print(#"{"ok":false,"error":"encode failed"}"#)
    }
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard !input.isEmpty,
      let req = try? JSONDecoder().decode(Request.self, from: input)
else {
    writeJSON(Response(ok: false, error: "Invalid JSON on stdin (expect system?, user, maxTokens?)"))
    exit(1)
}

#if canImport(FoundationModels)
if #available(macOS 26.0, *) {
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
        break
    case .unavailable(let reason):
        writeJSON(Response(ok: false, error: "Apple Intelligence unavailable: \(String(describing: reason))"))
        exit(2)
    @unknown default:
        if !model.isAvailable {
            writeJSON(Response(ok: false, error: "Apple Intelligence not available"))
            exit(2)
        }
    }

    let system = (req.system ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let instructions = system.isEmpty
        ? "You are a concise assistant. Reply with only the requested short text."
        : system
    let maxTokens = max(8, min(req.maxTokens ?? 48, 256))

    let sem = DispatchSemaphore(value: 0)
    var resultText: String?
    var resultError: String?

    Task {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(
                sampling: .greedy,
                temperature: 0.2,
                maximumResponseTokens: maxTokens
            )
            let response = try await session.respond(to: req.user, options: options)
            resultText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            resultError = error.localizedDescription
        }
        sem.signal()
    }

    // 60s timeout for short lightweight tasks
    let waited = sem.wait(timeout: .now() + 60)
    if waited == .timedOut {
        writeJSON(Response(ok: false, error: "Foundation model timed out"))
        exit(3)
    }
    if let err = resultError {
        writeJSON(Response(ok: false, error: err))
        exit(4)
    }
    guard let text = resultText, !text.isEmpty else {
        writeJSON(Response(ok: false, error: "Empty response from Foundation model"))
        exit(5)
    }
    writeJSON(Response(ok: true, text: text))
    exit(0)
} else {
    writeJSON(Response(ok: false, error: "Requires macOS 26+ for Apple Intelligence"))
    exit(2)
}
#else
writeJSON(Response(ok: false, error: "FoundationModels framework not available in this build"))
exit(2)
#endif
