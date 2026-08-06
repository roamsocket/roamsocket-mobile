import Foundation

/// A downloadable Metal / MLX chat model (never bundled in the app).
public struct LocalMetalCatalogEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { hubID }
    /// Hugging Face hub id, e.g. `lmstudio-community/Qwen3-1.7B-MLX-4bit`.
    public let hubID: String
    public let displayName: String
    /// Human size hint when known (e.g. `~0.7 GB`); may be empty for remote hits.
    public let approxSize: String
    /// Short description for family / detail UI.
    public let blurb: String
    /// Direct model page / download page on Hugging Face.
    public let downloadURL: URL
    /// Where this entry came from (for UI badges).
    public let source: Source
    /// Optional download popularity from Hugging Face.
    public let downloads: Int?
    /// UI chips (Recommended, Vision, Thinking, …).
    public let tags: [Tag]

    public enum Source: String, Codable, Sendable {
        /// Curated phone-friendly picks.
        case recommended
        /// mlx-swift-lm `LLMRegistry` (architectures known to work with this stack).
        case mlxSwiftRegistry
        /// Live LM Studio catalog on Hugging Face (`lmstudio-community`).
        case lmStudio
        /// Legacy decode for older caches that pulled `mlx-community`.
        case huggingFace
    }

    public enum Tag: String, Codable, Sendable, CaseIterable {
        case recommended
        case best
        case thinking
        case vision
        case new
        case experimental
        case legacy

        public var label: String {
            switch self {
            case .recommended: return "Recommended"
            case .best: return "Best"
            case .thinking: return "Thinking"
            case .vision: return "Vision"
            case .new: return "New"
            case .experimental: return "Experimental"
            case .legacy: return "Legacy"
            }
        }
    }

    /// Browse section on Manage models.
    public enum Section: String, Codable, Sendable {
        case featured
        case standard
        case experimental
        case legacy
    }

    public init(
        hubID: String,
        displayName: String,
        approxSize: String = "",
        blurb: String = "",
        downloadURL: URL? = nil,
        source: Source,
        downloads: Int? = nil,
        tags: [Tag] = []
    ) {
        self.hubID = hubID
        self.displayName = displayName
        self.approxSize = approxSize
        self.blurb = blurb
        self.downloadURL = downloadURL
            ?? URL(string: "https://huggingface.co/\(hubID)")!
        self.source = source
        self.downloads = downloads
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case hubID, displayName, approxSize, blurb, downloadURL, source, downloads, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hubID = try c.decode(String.self, forKey: .hubID)
        displayName = try c.decode(String.self, forKey: .displayName)
        approxSize = try c.decodeIfPresent(String.self, forKey: .approxSize) ?? ""
        blurb = try c.decodeIfPresent(String.self, forKey: .blurb) ?? ""
        downloadURL = try c.decodeIfPresent(URL.self, forKey: .downloadURL)
            ?? URL(string: "https://huggingface.co/\(hubID)")!
        source = try c.decode(Source.self, forKey: .source)
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads)
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
    }

    public var family: String {
        Self.familyName(for: hubID)
    }

    public var section: Section {
        if tags.contains(.legacy) || (source == .mlxSwiftRegistry && isLegacySized) {
            return .legacy
        }
        if tags.contains(.experimental)
            || source == .lmStudio
            || source == .huggingFace {
            return .experimental
        }
        if source == .recommended || tags.contains(.recommended) || tags.contains(.best) {
            return .featured
        }
        return .standard
    }

    private var isLegacySized: Bool {
        Self.matchesLegacyParameterSize(hubID)
    }

    public static func familyName(for hubID: String) -> String {
        let leaf = hubID.split(separator: "/").last.map(String.init) ?? hubID
        let lower = leaf.lowercased()
        if lower.contains("llama") { return "Llama" }
        if lower.contains("qwen") { return "Qwen" }
        if lower.contains("gemma") || lower.contains("medgemma") { return "Gemma" }
        // More specific families before short substrings (nemotron before "nemo").
        if lower.contains("nemotron") { return "Nemotron" }
        if lower.contains("mistral") || lower.contains("mixtral")
            || lower.contains("magistral") || lower.contains("devstral")
            || lower.contains("mistral-nemo") || lower.contains("ministral") {
            return "Mistral"
        }
        // Bare "nemo" only as a path segment (e.g. Mistral-Nemo-Instruct), not Nemotron.
        if lower.split(separator: "/").contains(where: { $0.contains("nemo") && !$0.contains("nemotron") })
            || lower.contains("-nemo-") || lower.hasSuffix("-nemo") {
            return "Mistral"
        }
        if lower.contains("phi") { return "Phi" }
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("smol") { return "SmolLM" }
        if lower.contains("granite") { return "Granite" }
        if lower.contains("lfm") { return "LFM" }
        if lower.contains("olmo") { return "OLMo" }
        if lower.contains("gpt") { return "GPT" }
        if lower.contains("openelm") { return "OpenELM" }
        if lower.contains("ernie") { return "ERNIE" }
        if lower.contains("glm") { return "GLM" }
        if lower.contains("bitnet") { return "BitNet" }
        if lower.contains("jamba") { return "Jamba" }
        if lower.contains("minimax") { return "MiniMax" }
        return "Other"
    }

    /// True for large parameter counts that are usually too heavy for phones.
    ///
    /// Token-based so `1.7B` does **not** match `7B` (substring trap).
    public static func matchesLegacyParameterSize(_ hubID: String) -> Bool {
        let leaf = hubID.split(separator: "/").last.map(String.init) ?? hubID
        let lower = leaf.lowercased()
        // Split on non-alphanumeric except `.` so `1.7b` stays one token.
        let tokens = lower.split { ch in
            !(ch.isLetter || ch.isNumber || ch == ".")
        }.map(String.init)
        let legacy: Set<String> = [
            "7b", "8b", "9b",
            "12b", "13b", "14b",
            "20b", "22b", "24b", "27b",
            "30b", "32b", "34b", "35b", "36b",
            "70b", "72b",
            // MoE sizes (single token when `x` is kept):
            "8x7b", "8x22b",
        ]
        if tokens.contains(where: { legacy.contains($0) }) { return true }
        // `72b-a12b` style after extra split still catches via 72b if present.
        return false
    }
}

// MARK: - Catalog service

/// Static registry + live pull from the LM Studio catalog on Hugging Face.
public actor LocalMetalCatalog {
    public static let shared = LocalMetalCatalog()

    /// Bumped when remote source changes so stale mlx-community caches are dropped.
    private let cacheKey = "localMetal.remoteCatalog.v2.lmstudio"
    private let cacheDateKey = "localMetal.remoteCatalog.fetchedAt.v2.lmstudio"
    private var remote: [LocalMetalCatalogEntry] = []
    private var lastFetch: Date?

    public init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([LocalMetalCatalogEntry].self, from: data) {
            remote = decoded
        }
        if let t = UserDefaults.standard.object(forKey: cacheDateKey) as? Date {
            lastFetch = t
        }
    }

    /// Full browse list: recommended → registry → remote LM Studio (deduped by hub id).
    public func allEntries(preferFreshRemote: Bool = false) async -> [LocalMetalCatalogEntry] {
        if preferFreshRemote || remote.isEmpty {
            _ = try? await refreshFromLMStudio()
        }
        return Self.merge(recommended: Self.recommended, registry: Self.registry, remote: remote)
            .map(Self.withFriendlyName)
    }

    public func lastRemoteFetchDate() -> Date? { lastFetch }

    /// Pretty name for a hub id from static catalogs, else a humanized leaf name.
    ///
    /// Always returns a friendly label (e.g. `Qwen 3 1.7B`), never a raw hub
    /// code name like `Qwen3-1.7B-MLX-4bit`.
    public static func displayName(for hubID: String) -> String {
        if let hit = recommended.first(where: { $0.hubID == hubID }) {
            return hit.displayName
        }
        return prettyName(from: hubID)
    }

    /// Copy of an entry with a friendly `displayName` (safe for cached remote rows).
    public static func withFriendlyName(_ entry: LocalMetalCatalogEntry) -> LocalMetalCatalogEntry {
        LocalMetalCatalogEntry(
            hubID: entry.hubID,
            displayName: displayName(for: entry.hubID),
            approxSize: entry.approxSize,
            blurb: entry.blurb,
            downloadURL: entry.downloadURL,
            source: entry.source,
            downloads: entry.downloads,
            tags: entry.tags
        )
    }

    /// Family-level blurb for the Manage models browser.
    public static func familyBlurb(_ family: String) -> String {
        switch family {
        case "Llama":
            return "Meta’s Llama instruct models. Strong general chat in compact sizes for on-device Metal."
        case "Qwen":
            return "Qwen models from the Qwen team. Strong multilingual chat and instruction following."
        case "Gemma":
            return "Google Gemma models — including Gemma 4 multimodal (vision + chat) and compact Gemma 3 chat variants for Metal."
        case "LFM":
            return "Liquid AI LFM models. Text chat and LFM2/LFM2.5 vision-language variants for on-device inference."
        case "Phi":
            return "Microsoft Phi instruct models. Compact reasoning and chat for smaller memory budgets."
        case "Mistral":
            return "Mistral instruct models. Capable chat; larger variants need more RAM."
        case "SmolLM":
            return "Ultra-small instruct models for quick replies and low storage use."
        case "Granite":
            return "IBM Granite instruct models for enterprise-style chat on device."
        case "DeepSeek":
            return "DeepSeek distill / reasoning models. Some variants emphasize chain-of-thought."
        case "GLM":
            return "Zhipu GLM models. Strong general chat; prefer Flash / smaller quants on phone."
        default:
            return "Open MLX models from the LM Studio catalog, ready for on-device Metal chat."
        }
    }

    /// Pull popular MLX models from the LM Studio Hugging Face org.
    @discardableResult
    public func refreshFromLMStudio() async throws -> [LocalMetalCatalogEntry] {
        // Public Hub API — no token required for listing.
        // https://huggingface.co/docs/hub/api
        // LM Studio publishes MLX weights under lmstudio-community (*-MLX-4bit, etc.).
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "author", value: "lmstudio-community"),
            URLQueryItem(name: "search", value: "MLX"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "150"),
            URLQueryItem(name: "full", value: "false"),
        ]
        guard let url = components.url else {
            throw ProviderError.transport("Invalid LM Studio catalog URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("AnyProvCode/1.0 (local-metal-catalog)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ProviderError.http(status: code, body: String(data: data, encoding: .utf8) ?? "")
        }

        let rows = try JSONDecoder().decode([HFModelRow].self, from: data)
        let mapped: [LocalMetalCatalogEntry] = rows.compactMap { row in
            guard row.id.lowercased().hasPrefix("lmstudio-community/") else { return nil }
            guard Self.isLikelyPhoneFriendly(
                hubID: row.id,
                tags: row.tags ?? [],
                pipelineTag: row.pipeline_tag
            ) else { return nil }
            let name = Self.prettyName(from: row.id)
            var uiTags: [LocalMetalCatalogEntry.Tag] = [.experimental]
            let idLower = row.id.lowercased()
            if idLower.contains("r1") || idLower.contains("reason") || idLower.contains("thinking") {
                uiTags.append(.thinking)
            }
            if idLower.contains("vl") || idLower.contains("vision") {
                uiTags.append(.vision)
            }
            if LocalMetalCatalogEntry.matchesLegacyParameterSize(row.id) {
                uiTags.append(.legacy)
            }
            return LocalMetalCatalogEntry(
                hubID: row.id,
                displayName: name,
                approxSize: "",
                blurb: "From the LM Studio catalog on Hugging Face. Prefer 4-bit models under ~4B on phones.",
                downloadURL: URL(string: "https://huggingface.co/\(row.id)")!,
                source: .lmStudio,
                downloads: row.downloads,
                tags: uiTags
            )
        }
        remote = mapped
        lastFetch = Date()
        if let encoded = try? JSONEncoder().encode(mapped) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
            UserDefaults.standard.set(lastFetch, forKey: cacheDateKey)
        }
        return mapped
    }

    /// - Note: Prefer `refreshFromLMStudio()`. Kept for call sites that still use the old name.
    @discardableResult
    public func refreshFromHuggingFace() async throws -> [LocalMetalCatalogEntry] {
        try await refreshFromLMStudio()
    }

    // MARK: - Merge / filter

    private static func merge(
        recommended: [LocalMetalCatalogEntry],
        registry: [LocalMetalCatalogEntry],
        remote: [LocalMetalCatalogEntry]
    ) -> [LocalMetalCatalogEntry] {
        var seen = Set<String>()
        var out: [LocalMetalCatalogEntry] = []
        for group in [recommended, registry, remote] {
            for entry in group {
                guard !seen.contains(entry.hubID) else { continue }
                seen.insert(entry.hubID)
                out.append(entry)
            }
        }
        return out
    }

    /// Prefer quantized / smaller instruct models for on-device chat.
    private static func isLikelyPhoneFriendly(
        hubID: String,
        tags: [String],
        pipelineTag: String? = nil
    ) -> Bool {
        let id = hubID.lowercased()
        // LM Studio catalog entries must be MLX format.
        guard id.contains("mlx") else { return false }
        // Skip vision / multimodal / audio / embedding for text chat browse.
        let pipe = (pipelineTag ?? "").lowercased()
        if pipe.contains("image") || pipe.contains("audio") || pipe == "any-to-any" {
            return false
        }
        if tags.contains(where: {
            let t = $0.lowercased()
            return t.contains("image-text") || t == "any-to-any" || t.contains("vision")
        }) {
            return false
        }
        if id.contains("vl") || id.contains("vision") || id.contains("whisper")
            || id.contains("embedding") || id.contains("tts")
            || id.contains("4.6v") || id.contains("-v-") {
            return false
        }
        if id.contains("70b") || id.contains("72b") || id.contains("80b")
            || id.contains("120b") || id.contains("405b") || id.contains("480b") {
            return false
        }
        // Prefer lower-bit quants for phone (LM Studio ships 4/5/6/8/bf16 of the same base).
        let lowBit = id.contains("4bit") || id.contains("3bit") || id.contains("2bit")
            || id.contains("4-bit") || id.contains("3-bit") || id.contains("2-bit")
        let midBit = id.contains("5bit") || id.contains("6bit")
        if id.contains("bf16") || id.contains("fp16") { return false }
        if id.contains("8bit") || id.contains("8-bit") { return false }
        if midBit { return false }
        // Keep conversational / instruct text models.
        let conversational = tags.contains("text-generation")
            || tags.contains("conversational")
            || id.contains("instruct")
            || id.contains("-it-")
            || id.contains("chat")
            || id.contains("thinking")
            || id.contains("reason")
            || id.contains("coder")
            || tags.isEmpty
        return lowBit && conversational
    }

    /// Turn a hub id / folder name into a friendly product-style label.
    ///
    /// Examples:
    /// - `lmstudio-community/Qwen3-1.7B-MLX-4bit` → `Qwen 3 1.7B`
    /// - `mlx-community/Meta-Llama-3.2-1B-Instruct-4bit` → `Llama 3.2 1B Instruct`
    /// - `Qwen3-4B-Thinking-2507-MLX-4bit` → `Qwen 3 4B Thinking 2507`
    public static func prettyName(from hubID: String) -> String {
        var leaf = hubID.trimmingCharacters(in: .whitespacesAndNewlines)
        if leaf.hasPrefix("local/") {
            leaf = String(leaf.dropFirst("local/".count))
        }
        // HF cache folder: models--org--name
        if leaf.hasPrefix("models--"),
           let hub = LocalMetalModelStore.hubID(fromRepoFolder: leaf) {
            leaf = hub
        }
        leaf = leaf.split(separator: "/").last.map(String.init) ?? leaf

        // Drop org prefixes that are baked into the repo leaf.
        let orgPrefixes = [
            "Meta-", "meta-", "META-",
            "Google-", "google-",
            "Microsoft-", "microsoft-",
            "IBM-", "ibm-",
            "NousResearch-", "nousresearch-",
        ]
        for prefix in orgPrefixes where leaf.hasPrefix(prefix) {
            leaf = String(leaf.dropFirst(prefix.count))
            break
        }

        // Strip packaging / quant / runtime noise (longest first). Keep capability
        // words like Instruct, Thinking, Coder, Reasoning — only drop the format tail.
        let dropFragments = [
            "-MLX-4bit", "-MLX-5bit", "-MLX-6bit", "-MLX-8bit",
            "-MLX-3bit", "-MLX-2bit", "-MLX-bf16", "-MLX-fp16", "-MLX",
            "-4bit", "-5bit", "-6bit", "-8bit", "-3bit", "-2bit",
            "-4-bit", "-5-bit", "-6-bit", "-8-bit", "-3-bit", "-2-bit",
            "-bf16", "-fp16", "-DWQ", "-MXFP4-Q8", "-MXFP4",
            "-GGUF", "-gguf",
        ]
        var s = leaf
        for frag in dropFragments.sorted(by: { $0.count > $1.count }) {
            s = s.replacingOccurrences(of: frag, with: "", options: .caseInsensitive)
        }

        // Normalize separators.
        s = s
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: ".") // keep version dots

        // Insert a space between brand letters and a leading version digit:
        // Qwen3 → Qwen 3, Llama3 → Llama 3, Gemma3n → Gemma 3n, LFM2 → LFM 2.
        let brands = [
            "Qwen", "Llama", "Gemma", "Phi", "OLMo", "GLM", "ERNIE",
            "SmolLM", "DeepSeek", "Granite", "OpenELM", "LFM", "BitNet",
            "Jamba", "Nemotron", "MiniMax", "MiMo", "Baichuan", "AceReason",
            "Exaone", "Ling",
        ]
        for brand in brands {
            guard let regex = try? NSRegularExpression(
                pattern: "(\\b\(NSRegularExpression.escapedPattern(for: brand)))(\\d)",
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "$1 $2")
        }

        // Token cleanup / capitalization.
        let tokens = s
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
            .compactMap { token -> String? in
                let lower = token.lowercased()
                // Drop bare instruction-tuned marker Google uses (`it`).
                if lower == "it" { return nil }
                // Drop leftover packaging tokens.
                if lower == "mlx" || lower == "gguf" || lower == "dwq" { return nil }
                if lower.hasSuffix("bit"), lower.dropLast(3).allSatisfy({ $0.isNumber || $0 == "-" }) {
                    return nil
                }
                // Size markers: 1.7B, 270M, 0.6B
                if let sized = normalizeSizeToken(token) { return sized }
                // Capability / role words.
                switch lower {
                case "instruct", "instruction": return "Instruct"
                case "thinking": return "Thinking"
                case "reasoning", "reason": return "Reasoning"
                case "coder", "code": return "Coder"
                case "chat": return "Chat"
                case "mini": return "Mini"
                case "distill": return "Distill"
                case "vision", "vl": return "Vision"
                case "qat": return "QAT"
                case "sft": return "SFT"
                case "r1": return "R1"
                case "pt": return nil // pretrained marker
                case "ft": return nil // fine-tune marker
                default:
                    break
                }
                // Preserve mixed-case brands (Qwen, LFM, SmolLM); title-case plain words.
                if token == token.uppercased(), token.count <= 5 {
                    return token // acronyms like LFM, GLM, QAT already handled
                }
                if token.first?.isLowercase == true {
                    return token.prefix(1).uppercased() + token.dropFirst()
                }
                return token
            }

        let joined = tokens.joined(separator: " ")
        return joined.isEmpty ? leaf.replacingOccurrences(of: "-", with: " ") : joined
    }

    /// `1.7b` / `270m` → `1.7B` / `270M`.
    private static func normalizeSizeToken(_ token: String) -> String? {
        let pattern = #"^(\d+(?:\.\d+)?)([bBmMkK])$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: token, range: NSRange(token.startIndex..<token.endIndex, in: token)),
              let numRange = Range(match.range(at: 1), in: token),
              let unitRange = Range(match.range(at: 2), in: token)
        else { return nil }
        return String(token[numRange]) + token[unitRange].uppercased()
    }

    // MARK: - Static catalogs

    /// Hand-picked for iPhone-class RAM from the LM Studio MLX catalog (≈ ≤ 4B 4-bit).
    public static let recommended: [LocalMetalCatalogEntry] = [
        .init(
            hubID: "lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit",
            displayName: "LFM2.5 1.2B",
            approxSize: "~0.7 GB",
            blurb: "Liquid AI LFM2.5 — strong everyday chat and a great on-device starting point.",
            source: .recommended,
            tags: [.recommended, .best, .new]
        ),
        .init(
            hubID: "lmstudio-community/Qwen3-0.6B-MLX-4bit",
            displayName: "Qwen 3 0.6B",
            approxSize: "~0.4 GB",
            blurb: "Tiny Qwen 3 for low storage and fast replies.",
            source: .recommended,
            tags: [.recommended, .new]
        ),
        .init(
            hubID: "lmstudio-community/Qwen3-1.7B-MLX-4bit",
            displayName: "Qwen 3 1.7B",
            approxSize: "~1.0 GB",
            blurb: "Balanced Qwen 3 size for everyday on-device chat.",
            source: .recommended,
            tags: [.recommended, .new]
        ),
        .init(
            hubID: "lmstudio-community/Qwen3-4B-Instruct-2507-MLX-4bit",
            displayName: "Qwen 3 4B Instruct",
            approxSize: "~2.3 GB",
            blurb: "Stronger Qwen 3 instruct. Best on iPhone 15 Pro and newer with free RAM.",
            source: .recommended,
            tags: [.recommended, .new]
        ),
        .init(
            hubID: "lmstudio-community/Qwen3-4B-Thinking-2507-MLX-4bit",
            displayName: "Qwen 3 4B Thinking",
            approxSize: "~2.3 GB",
            blurb: "Qwen 3 thinking variant for chain-of-thought style replies.",
            source: .recommended,
            tags: [.recommended, .thinking, .new]
        ),
        .init(
            hubID: "lmstudio-community/Qwen2.5-0.5B-Instruct-MLX-4bit",
            displayName: "Qwen 2.5 0.5B",
            approxSize: "~0.3 GB",
            blurb: "Ultra-small Qwen 2.5 instruct for smoke tests and tight storage.",
            source: .recommended,
            tags: [.recommended]
        ),
        .init(
            hubID: "lmstudio-community/Qwen2.5-1.5B-Instruct-MLX-4bit",
            displayName: "Qwen 2.5 1.5B",
            approxSize: "~0.9 GB",
            blurb: "Compact multilingual instruct model with solid multi-turn chat.",
            source: .recommended,
            tags: [.recommended]
        ),
        .init(
            hubID: "lmstudio-community/Qwen2.5-3B-Instruct-MLX-4bit",
            displayName: "Qwen 2.5 3B",
            approxSize: "~1.8 GB",
            blurb: "Larger Qwen 2.5 instruct for higher-quality chat when RAM allows.",
            source: .recommended,
            tags: [.recommended]
        ),
        .init(
            hubID: "lmstudio-community/Qwen2.5-Coder-1.5B-Instruct-MLX-4bit",
            displayName: "Qwen 2.5 Coder 1.5B",
            approxSize: "~0.9 GB",
            blurb: "Small code-focused instruct model for on-device coding chat.",
            source: .recommended,
            tags: [.recommended]
        ),
        .init(
            hubID: "lmstudio-community/Qwen2.5-Coder-3B-Instruct-MLX-4bit",
            displayName: "Qwen 2.5 Coder 3B",
            approxSize: "~1.8 GB",
            blurb: "Stronger code chat when you can spare the RAM.",
            source: .recommended,
            tags: [.recommended]
        ),
        .init(
            hubID: "lmstudio-community/Phi-4-mini-reasoning-MLX-4bit",
            displayName: "Phi 4 Mini Reasoning",
            approxSize: "~2.2 GB",
            blurb: "Microsoft Phi 4 mini for compact reasoning and chat.",
            source: .recommended,
            tags: [.recommended, .thinking, .new]
        ),
        .init(
            hubID: "lmstudio-community/Qwen3.5-2B-MLX-4bit",
            displayName: "Qwen 3.5 2B",
            approxSize: "~1.2 GB",
            blurb: "Newer Qwen 3.5 mid-size for general on-device chat.",
            source: .recommended,
            tags: [.recommended, .new]
        ),
        .init(
            hubID: "lmstudio-community/gemma-3-270m-it-qat-MLX-4bit",
            displayName: "Gemma 3 270M QAT",
            approxSize: "~0.2 GB",
            blurb: "Tiny Gemma for smoke tests and ultra-low storage.",
            source: .recommended,
            tags: [.recommended]
        ),
        .init(
            hubID: "lmstudio-community/gemma-3n-E2B-it-MLX-4bit",
            displayName: "Gemma 3n E2B",
            approxSize: "~1.5 GB",
            blurb: "Google Gemma 3n E2B instruct for multi-turn chat on device.",
            source: .recommended,
            tags: [.recommended, .new]
        ),

        // MARK: Vision (Apple Silicon / MLX VLMs — phone-friendly first)
        // Hub ids verified on Hugging Face (mlx-community / lmstudio-community), Aug 2026.
        // Gemma 4 family: E2B/E4B (edge) + 12B Unified QAT (June 2026 encoder-free multimodal).
        .init(
            hubID: "mlx-community/gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B",
            approxSize: "~2 GB",
            blurb: "Google Gemma 4 E2B — natively multimodal (image + text). Best on-device Vision starter.",
            source: .recommended,
            tags: [.recommended, .vision, .best, .new]
        ),
        .init(
            hubID: "mlx-community/gemma-4-e4b-it-4bit",
            displayName: "Gemma 4 E4B",
            approxSize: "~3 GB",
            blurb: "Gemma 4 E4B multimodal. Stronger vision + chat; needs more free RAM (15 Pro class+).",
            source: .recommended,
            tags: [.recommended, .vision, .new]
        ),
        .init(
            hubID: "mlx-community/gemma-4-12B-it-qat-4bit",
            displayName: "Gemma 4 12B Unified",
            approxSize: "~7 GB",
            blurb: "Gemma 4 12B Unified QAT (June 2026) — encoder-free multimodal. High-end / iPad class RAM only.",
            source: .recommended,
            tags: [.vision, .new, .experimental]
        ),
        .init(
            hubID: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            displayName: "Qwen3-VL 2B",
            approxSize: "~1.5 GB",
            blurb: "Latest Qwen3 vision-language 2B. Fast photo analysis and OCR on phone-class devices.",
            source: .recommended,
            tags: [.recommended, .vision, .new]
        ),
        .init(
            hubID: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            displayName: "Qwen3-VL 4B",
            approxSize: "~2.5 GB",
            blurb: "Qwen3-VL 4B — top phone-class VLM quality when you can spare the RAM.",
            source: .recommended,
            tags: [.recommended, .vision, .new]
        ),
        .init(
            hubID: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
            displayName: "Qwen2.5-VL 3B",
            approxSize: "~2 GB",
            blurb: "Qwen2.5 vision instruct — strong OCR, documents, and scene understanding.",
            source: .recommended,
            tags: [.recommended, .vision]
        ),
        .init(
            hubID: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
            displayName: "Qwen2-VL 2B",
            approxSize: "~1.5 GB",
            blurb: "Compact Qwen2 vision-language model. Lightweight photo analysis.",
            source: .recommended,
            tags: [.recommended, .vision]
        ),
        .init(
            hubID: "mlx-community/gemma-3-4b-it-qat-4bit",
            displayName: "Gemma 3 4B Vision",
            approxSize: "~2.5 GB",
            blurb: "Gemma 3 4B multimodal (image + text). Proven all-rounder for Vision mode.",
            source: .recommended,
            tags: [.recommended, .vision]
        ),
        .init(
            hubID: "mlx-community/LFM2.5-VL-1.6B-4bit",
            displayName: "LFM2.5-VL 1.6B",
            approxSize: "~1.2 GB",
            blurb: "Liquid AI LFM2.5 vision-language — newer edge VLM for Apple Silicon.",
            source: .recommended,
            tags: [.recommended, .vision, .new]
        ),
        .init(
            hubID: "mlx-community/LFM2.5-VL-450M-6bit",
            displayName: "LFM2.5-VL 450M",
            approxSize: "~0.5 GB",
            blurb: "Tiny Liquid AI vision model. Lowest storage among current LFM VLMs.",
            source: .recommended,
            tags: [.recommended, .vision, .new]
        ),
        .init(
            hubID: "mlx-community/LFM2-VL-1.6B-4bit",
            displayName: "LFM2-VL 1.6B",
            approxSize: "~1.2 GB",
            blurb: "Liquid AI LFM2 edge vision model (prior gen). Compact multimodal chat.",
            source: .recommended,
            tags: [.recommended, .vision]
        ),
        .init(
            hubID: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
            displayName: "SmolVLM2 500M",
            approxSize: "~0.6 GB",
            blurb: "Hugging Face SmolVLM2 — tiny image/video instruct VLM for quick on-device analysis.",
            source: .recommended,
            tags: [.recommended, .vision, .new]
        ),
        .init(
            hubID: "mlx-community/SmolVLM-256M-Instruct-4bit",
            displayName: "SmolVLM 256M",
            approxSize: "~0.3 GB",
            blurb: "Ultra-small SmolVLM for smoke tests and tight storage.",
            source: .recommended,
            tags: [.recommended, .vision, .new]
        ),
        .init(
            hubID: "mlx-community/SmolVLM-Instruct-4bit",
            displayName: "SmolVLM",
            approxSize: "~1 GB",
            blurb: "Original SmolVLM instruct — light footprint for quick photo captions.",
            source: .recommended,
            tags: [.recommended, .vision]
        ),
        .init(
            hubID: "mlx-community/FastVLM-0.5B-bf16",
            displayName: "FastVLM 0.5B",
            approxSize: "~1 GB",
            blurb: "Very small fast vision model for smoke tests and low storage.",
            source: .recommended,
            tags: [.recommended, .vision]
        ),
        .init(
            hubID: "mlx-community/PaddleOCR-VL-1.5-bf16",
            displayName: "PaddleOCR-VL 1.5",
            approxSize: "~1 GB",
            blurb: "Document-focused VLM (OCR, tables, layout). Great for screenshots and PDFs.",
            source: .recommended,
            tags: [.recommended, .vision, .new]
        ),
    ]

    /// Models registered in mlx-swift-lm `LLMRegistry` (architectures supported by this stack).
    /// Source of truth: https://github.com/ml-explore/mlx-swift-lm (LLMModelFactory).
    /// Hub ids remain mostly mlx-community; recommended + live catalog use LM Studio.
    public static let registry: [LocalMetalCatalogEntry] = [
        "mlx-community/SmolLM-135M-Instruct-4bit",
        "mlx-community/Mistral-Nemo-Instruct-2407-4bit",
        "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
        "mlx-community/CodeLlama-13b-Instruct-hf-4bit-MLX",
        "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
        "mlx-community/phi-2-hf-4bit-mlx",
        "mlx-community/Phi-3.5-mini-instruct-4bit",
        "mlx-community/Phi-3.5-MoE-instruct-4bit",
        "mlx-community/quantized-gemma-2b-it",
        "mlx-community/gemma-2-9b-it-4bit",
        "mlx-community/gemma-2-2b-it-4bit",
        "mlx-community/gemma-3-1b-it-qat-4bit",
        "mlx-community/gemma-3n-E4B-it-lm-4bit",
        "mlx-community/gemma-3n-E2B-it-lm-4bit",
        "mlx-community/gemma-4-e4b-it-4bit",
        "mlx-community/gemma-4-e2b-it-4bit",
        "mlx-community/gemma-4-12B-it-qat-4bit",
        // Vision-language (MLXVLM)
        "mlx-community/Qwen2-VL-2B-Instruct-4bit",
        "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
        "mlx-community/Qwen3-VL-2B-Instruct-4bit",
        "mlx-community/Qwen3-VL-4B-Instruct-4bit",
        "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
        "mlx-community/gemma-3-4b-it-qat-4bit",
        "mlx-community/SmolVLM-Instruct-4bit",
        "mlx-community/SmolVLM-256M-Instruct-4bit",
        "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
        "mlx-community/LFM2-VL-1.6B-4bit",
        "mlx-community/LFM2.5-VL-1.6B-4bit",
        "mlx-community/LFM2.5-VL-450M-6bit",
        "mlx-community/LFM2-VL-450M-4bit",
        "mlx-community/FastVLM-0.5B-bf16",
        "mlx-community/PaddleOCR-VL-1.5-bf16",
        "mlx-community/Qwen1.5-0.5B-Chat-4bit",
        "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        "mlx-community/Qwen3-0.6B-4bit",
        "mlx-community/Qwen3-1.7B-4bit",
        "mlx-community/Qwen3-4B-4bit",
        "mlx-community/Qwen3-8B-4bit",
        "mlx-community/Qwen3-30B-A3B-4bit",
        "mlx-community/Qwen3.5-2B-4bit",
        "mlx-community/OpenELM-270M-Instruct",
        "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
        "mlx-community/Meta-Llama-3-8B-Instruct-4bit",
        "mlx-community/Llama-3.2-1B-Instruct-4bit",
        "mlx-community/Llama-3.2-3B-Instruct-4bit",
        "mlx-community/DeepSeek-R1-4bit",
        "mlx-community/granite-3.3-2b-instruct-4bit",
        "mlx-community/MiMo-7B-SFT-4bit",
        "mlx-community/GLM-4-9B-0414-4bit",
        "mlx-community/AceReason-Nemotron-7B-4bit",
        "mlx-community/bitnet-b1.58-2B-4T-4bit",
        "mlx-community/Baichuan-M1-14B-Instruct-4bit-ft",
        "mlx-community/SmolLM3-3B-4bit",
        "mlx-community/ERNIE-4.5-0.3B-PT-bf16-ft",
        "mlx-community/LFM2-1.2B-4bit",
        "mlx-community/exaone-4.0-1.2b-4bit",
        "mlx-community/lille-130m-instruct-bf16",
        "mlx-community/OLMoE-1B-7B-0125-Instruct-4bit",
        "mlx-community/OLMo-2-1124-7B-Instruct-4bit",
        "mlx-community/Ling-mini-2.0-2bit-DWQ",
        "mlx-community/Granite-4.0-H-Tiny-4bit-DWQ",
        "mlx-community/LFM2-8B-A1B-3bit-MLX",
        "dnakov/nanochat-d20-mlx",
        "mlx-community/gpt-oss-20b-MXFP4-Q8",
        "mlx-community/AI21-Jamba-Reasoning-3B-4bit",
        "mlx-community/Nemotron-Labs-Diffusion-3B-4bit",
    ].map { hub -> LocalMetalCatalogEntry in
        var tags: [LocalMetalCatalogEntry.Tag] = []
        let lower = hub.lowercased()
        if lower.contains("r1") || lower.contains("reason") { tags.append(.thinking) }
        let isVision =
            lower.contains("gemma-4") || lower.contains("gemma4")
            || lower.contains("gemma-3-4b") || lower.contains("gemma-3-12b") || lower.contains("gemma-3-27b")
            || lower.contains("paligemma") || lower.contains("smolvlm") || lower.contains("fastvlm")
            || lower.contains("qwen2-vl") || lower.contains("qwen2.5-vl") || lower.contains("qwen3-vl")
            || lower.contains("lfm2-vl") || lower.contains("lfm2.5-vl")
            || lower.contains("paddleocr") || lower.contains("moondream") || lower.contains("pixtral")
            || lower.contains("kimi-vl") || lower.contains("mage-vl")
            || lower.contains("-vl-") || lower.contains("vision") || lower.contains("vlm")
        if isVision { tags.append(.vision) }
        if LocalMetalCatalogEntry.matchesLegacyParameterSize(hub) {
            tags.append(.legacy)
        }
        return LocalMetalCatalogEntry(
            hubID: hub,
            displayName: prettyName(from: hub),
            approxSize: "",
            blurb: isVision
                ? "Vision-language model (MLXVLM). Download for on-device photo analysis."
                : "Registered for mlx-swift-lm. Larger sizes may be slow or fail on phone RAM.",
            source: .mlxSwiftRegistry,
            tags: tags
        )
    }

    private struct HFModelRow: Decodable {
        let id: String
        let downloads: Int?
        let tags: [String]?
        let pipeline_tag: String?
    }
}
