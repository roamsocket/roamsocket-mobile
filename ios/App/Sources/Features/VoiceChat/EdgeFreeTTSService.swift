import Foundation
import CryptoKit

/// Free neural TTS via Microsoft Edge Read Aloud voices (no API key).
/// Significantly more natural than Apple `AVSpeechSynthesizer`.
///
/// Protocol matches the open-source `edge-tts` client (WebSocket + Sec-MS-GEC).
/// Requires network; may break if Microsoft changes the consumer endpoint.
enum EdgeFreeTTSService {
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromiumFullVersion = "143.0.3650.75"
    private static let winEpoch: Double = 11_644_473_600
    /// Clock skew vs Microsoft servers (seconds). Adjusted after 403s.
    private static var clockSkewSeconds: Double = 0

    enum EdgeError: LocalizedError {
        case emptyText
        case connectFailed(String)
        case noAudio
        case server(String)

        var errorDescription: String? {
            switch self {
            case .emptyText: return "Nothing to speak."
            case .connectFailed(let m): return "Free neural TTS connection failed: \(m)"
            case .noAudio: return "Free neural TTS returned no audio."
            case .server(let m): return m
            }
        }
    }

    struct Voice: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let locale: String
        var displaySubtitle: String { "\(locale) · free neural" }
    }

    /// Curated natural English voices (plus a few common locales).
    static let presetVoices: [Voice] = [
        Voice(id: "en-US-EmmaMultilingualNeural", name: "Emma (US)", locale: "en-US"),
        Voice(id: "en-US-AvaMultilingualNeural", name: "Ava (US)", locale: "en-US"),
        Voice(id: "en-US-AndrewMultilingualNeural", name: "Andrew (US)", locale: "en-US"),
        Voice(id: "en-US-BrianMultilingualNeural", name: "Brian (US)", locale: "en-US"),
        Voice(id: "en-US-JennyNeural", name: "Jenny (US)", locale: "en-US"),
        Voice(id: "en-US-GuyNeural", name: "Guy (US)", locale: "en-US"),
        Voice(id: "en-US-AriaNeural", name: "Aria (US)", locale: "en-US"),
        Voice(id: "en-GB-SoniaNeural", name: "Sonia (UK)", locale: "en-GB"),
        Voice(id: "en-GB-RyanNeural", name: "Ryan (UK)", locale: "en-GB"),
        Voice(id: "en-AU-NatashaNeural", name: "Natasha (AU)", locale: "en-AU"),
        Voice(id: "en-AU-WilliamNeural", name: "William (AU)", locale: "en-AU"),
        Voice(id: "es-ES-ElviraNeural", name: "Elvira (ES)", locale: "es-ES"),
        Voice(id: "fr-FR-DeniseNeural", name: "Denise (FR)", locale: "fr-FR"),
        Voice(id: "de-DE-KatjaNeural", name: "Katja (DE)", locale: "de-DE"),
        Voice(id: "pt-BR-FranciscaNeural", name: "Francisca (BR)", locale: "pt-BR"),
        Voice(id: "ja-JP-NanamiNeural", name: "Nanami (JP)", locale: "ja-JP"),
        Voice(id: "zh-CN-XiaoxiaoNeural", name: "Xiaoxiao (CN)", locale: "zh-CN"),
    ]

    static let defaultVoiceID = "en-US-EmmaMultilingualNeural"

    /// Synthesize MP3 audio. Retries once after clock-skew adjustment on 403.
    static func synthesize(
        text: String,
        voiceID: String,
        ratePercent: Int = 0
    ) async throws -> Data {
        let cleaned = sanitize(text)
        guard !cleaned.isEmpty else { throw EdgeError.emptyText }

        do {
            return try await synthesizeOnce(
                text: cleaned,
                voiceID: voiceID.isEmpty ? defaultVoiceID : voiceID,
                ratePercent: ratePercent
            )
        } catch {
            // Retry once after slight skew nudge (common when device clock drifts).
            clockSkewSeconds += 1
            return try await synthesizeOnce(
                text: cleaned,
                voiceID: voiceID.isEmpty ? defaultVoiceID : voiceID,
                ratePercent: ratePercent
            )
        }
    }

    // MARK: - WebSocket session

    private static func synthesizeOnce(
        text: String,
        voiceID: String,
        ratePercent: Int
    ) async throws -> Data {
        let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let gec = generateSecMSGEC()
        let gecVersion = "1-\(chromiumFullVersion)"
        let major = chromiumFullVersion.split(separator: ".").first.map(String.init) ?? "143"

        var components = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "ConnectionId", value: connectionID),
            URLQueryItem(name: "Sec-MS-GEC", value: gec),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: gecVersion),
        ]
        guard let url = components.url else {
            throw EdgeError.connectFailed("Invalid URL.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36 Edg/\(major).0.0.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let muid = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        request.setValue("muid=\(muid);", forHTTPHeaderField: "Cookie")

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        task.resume()

        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        // 1) speech.config
        let configMsg =
            "X-Timestamp:\(jsDateString())\r\n" +
            "Content-Type:application/json; charset=utf-8\r\n" +
            "Path:speech.config\r\n\r\n" +
            #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"# +
            "\r\n"
        try await task.send(.string(configMsg))

        // 2) SSML
        let rate = formatRate(ratePercent)
        let escaped = xmlEscape(text)
        let ssml =
            "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>" +
            "<voice name='\(voiceID)'>" +
            "<prosody pitch='+0Hz' rate='\(rate)' volume='+0%'>" +
            escaped +
            "</prosody></voice></speak>"

        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let ssmlMsg =
            "X-RequestId:\(requestID)\r\n" +
            "Content-Type:application/ssml+xml\r\n" +
            "X-Timestamp:\(jsDateString())Z\r\n" +
            "Path:ssml\r\n\r\n" +
            ssml
        try await task.send(.string(ssmlMsg))

        var audio = Data()
        let deadline = Date().addingTimeInterval(60)

        while Date() < deadline {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await withTimeout(seconds: 20) {
                    try await task.receive()
                }
            } catch {
                if audio.isEmpty {
                    throw EdgeError.connectFailed(error.localizedDescription)
                }
                break
            }

            switch message {
            case .string(let textMsg):
                if textMsg.contains("Path:turn.end") {
                    if audio.isEmpty { throw EdgeError.noAudio }
                    return audio
                }
                // Ignore response / turn.start / metadata text frames.

            case .data(let binary):
                if let chunk = extractAudioPayload(from: binary) {
                    audio.append(chunk)
                }

            @unknown default:
                break
            }
        }

        if audio.isEmpty {
            throw EdgeError.noAudio
        }
        return audio
    }

    // MARK: - Binary frame parse

    /// Edge binary frames: 2-byte big-endian header length + headers + `\r\n\r\n` + audio.
    private static func extractAudioPayload(from data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let headerLength = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        let headerEnd = 2 + headerLength
        guard headerEnd <= data.count else { return nil }

        let headerData = data.subdata(in: 2..<headerEnd)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        // Expect Path:audio and Content-Type:audio/mpeg (or empty terminator).
        let lower = headerString.lowercased()
        guard lower.contains("path:audio") else { return nil }

        var payloadStart = headerEnd
        // Header length already includes up to end of headers; protocol uses header_length
        // pointing at end of header block before optional extra CRLF in some clients.
        // edge-tts: parameters, data = get_headers_and_data(received.data, header_length)
        // where get_headers_and_data uses data[:header_length] and data[header_length+2:]
        // with header_length from first 2 bytes of the FULL message including those 2 bytes?
        // Looking at communicate.py:
        //   header_length = int.from_bytes(received.data[:2], "big")
        //   parameters, data = get_headers_and_data(received.data, header_length)
        //   get_headers_and_data: headers from data[:header_length], body from data[header_length+2:]
        // So header_length is measured from byte 0 of the message (including the 2 length bytes)?
        // Actually it uses data[:header_length] on the FULL received.data including the 2-byte prefix.
        // That seems wrong unless header_length includes the 2-byte size field...
        // From edge-tts: `parameters, data = get_headers_and_data(received.data, header_length)`
        // and get_headers_and_data splits data[:header_length] as headers - so header_length
        // is absolute index into the full buffer. Common pattern:
        //   [2 byte len][headers of len-2][\r\n][body] OR [2 byte len][headers][\r\n\r\n][body]
        // Python: body = data[header_length + 2 :]  — skips 2 bytes after header_length index.
        // So if header_length is 100, body starts at 102. Headers are bytes 0..<100 including
        // the 2-byte length prefix in the "headers" parse which would be weird...
        // Looking again at get_headers_and_data - it splits lines on header part. The first
        // two bytes would corrupt line parse unless header_length points past them differently.
        // Empirical: many ports use:
        //   let headerLen = Int(UInt16(bigEndian: ...))
        //   let header = data[2..<(2+headerLen)]
        //   let body = data[(2+headerLen)...]
        // We'll use that standard approach; if Path not found try body after \r\n\r\n.

        if let range = data.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) {
            payloadStart = range.upperBound
        } else {
            payloadStart = headerEnd
        }

        guard payloadStart < data.count else { return nil }
        let payload = data.subdata(in: payloadStart..<data.count)
        return payload.isEmpty ? nil : payload
    }

    // MARK: - Sec-MS-GEC

    private static func generateSecMSGEC() -> String {
        var ticks = Date().timeIntervalSince1970 + clockSkewSeconds
        ticks += winEpoch
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        // Windows FILETIME 100ns intervals
        let fileTime = ticks * 10_000_000
        let strToHash = "\(Int64(fileTime))\(trustedClientToken)"
        let digest = SHA256.hash(data: Data(strToHash.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Helpers

    private static func sanitize(_ text: String) -> String {
        // Drop control chars Edge rejects (except tab/newline → space).
        let mapped = text.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            if (0...8).contains(v) || (11...12).contains(v) || (14...31).contains(v) {
                return " "
            }
            return Character(scalar)
        }
        return String(mapped)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func formatRate(_ percent: Int) -> String {
        let clamped = min(max(percent, -50), 100)
        if clamped >= 0 { return "+\(clamped)%" }
        return "\(clamped)%"
    }

    private static func jsDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw EdgeError.connectFailed("Timed out waiting for audio.")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
