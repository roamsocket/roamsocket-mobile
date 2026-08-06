import Foundation

/// A downloadable Metal / MLX chat model (never bundled in the app).
public struct LocalMetalCatalogEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { hubID }
    /// Hugging Face hub id, e.g. `mlx-community/Llama-3.2-1B-Instruct-4bit`.
    public let hubID: String
    public let displayName: String
    /// Human size hint when known (e.g. `~0.7 GB`); may be empty for remote hits.
    public let approxSize: String
    /// Direct model page / download page on Hugging Face.
    public let downloadURL: URL
    /// Where this entry came from (for UI badges).
    public let source: Source
    /// Optional download popularity from Hugging Face.
    public let downloads: Int?

    public enum Source: String, Codable, Sendable {
        /// Curated phone-friendly picks.
        case recommended
        /// mlx-swift-lm `LLMRegistry` (architectures known to work with this stack).
        case mlxSwiftRegistry
        /// Live Hugging Face `mlx-community` listing.
        case huggingFace
    }

    public init(
        hubID: String,
        displayName: String,
        approxSize: String = "",
        downloadURL: URL? = nil,
        source: Source,
        downloads: Int? = nil
    ) {
        self.hubID = hubID
        self.displayName = displayName
        self.approxSize = approxSize
        self.downloadURL = downloadURL
            ?? URL(string: "https://huggingface.co/\(hubID)")!
        self.source = source
        self.downloads = downloads
    }

    public var family: String {
        let leaf = hubID.split(separator: "/").last.map(String.init) ?? hubID
        let lower = leaf.lowercased()
        if lower.contains("llama") { return "Llama" }
        if lower.contains("qwen") { return "Qwen" }
        if lower.contains("gemma") { return "Gemma" }
        if lower.contains("mistral") || lower.contains("mixtral") { return "Mistral" }
        if lower.contains("phi") { return "Phi" }
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("smol") { return "SmolLM" }
        if lower.contains("granite") { return "Granite" }
        if lower.contains("lfm") { return "LFM" }
        if lower.contains("olmo") { return "OLMo" }
        if lower.contains("gpt") { return "GPT" }
        return "Other"
    }
}

// MARK: - Catalog service

/// Static registry + optional live pull from Hugging Face mlx-community.
public actor LocalMetalCatalog {
    public static let shared = LocalMetalCatalog()

    private let cacheKey = "localMetal.remoteCatalog.v1"
    private let cacheDateKey = "localMetal.remoteCatalog.fetchedAt.v1"
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

    /// Full browse list: recommended → registry → remote HF (deduped by hub id).
    public func allEntries(preferFreshRemote: Bool = false) async -> [LocalMetalCatalogEntry] {
        if preferFreshRemote || remote.isEmpty {
            _ = try? await refreshFromHuggingFace()
        }
        return Self.merge(recommended: Self.recommended, registry: Self.registry, remote: remote)
    }

    public func lastRemoteFetchDate() -> Date? { lastFetch }

    /// Pull popular text-generation MLX models from Hugging Face (mlx-community).
    @discardableResult
    public func refreshFromHuggingFace() async throws -> [LocalMetalCatalogEntry] {
        // Public Hub API — no token required for listing.
        // https://huggingface.co/docs/hub/api
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "author", value: "mlx-community"),
            URLQueryItem(name: "filter", value: "text-generation"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "120"),
            URLQueryItem(name: "full", value: "false"),
        ]
        guard let url = components.url else {
            throw ProviderError.transport("Invalid Hugging Face catalog URL.")
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
            guard Self.isLikelyPhoneFriendly(hubID: row.id, tags: row.tags ?? []) else { return nil }
            let name = Self.prettyName(from: row.id)
            return LocalMetalCatalogEntry(
                hubID: row.id,
                displayName: name,
                approxSize: "",
                downloadURL: URL(string: "https://huggingface.co/\(row.id)")!,
                source: .huggingFace,
                downloads: row.downloads
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
    private static func isLikelyPhoneFriendly(hubID: String, tags: [String]) -> Bool {
        let id = hubID.lowercased()
        // Skip obvious vision / audio / huge MoE monsters for the default list.
        if id.contains("vl") || id.contains("vision") || id.contains("whisper") { return false }
        if id.contains("70b") || id.contains("72b") || id.contains("405b") { return false }
        // Prefer 4bit / 3bit / 2bit / qat / dwq / mxfp quantizations when tagged in name.
        let quantized = id.contains("4bit") || id.contains("3bit") || id.contains("2bit")
            || id.contains("8bit") || id.contains("qat") || id.contains("dwq")
            || id.contains("mxfp") || id.contains("quantized") || id.contains("mlx")
        // HF mlx-community models are already MLX; keep conversational text models.
        if tags.contains("text-generation") || tags.contains("conversational") || tags.isEmpty {
            return quantized || id.contains("instruct") || id.contains("-it-") || id.contains("chat")
        }
        return quantized
    }

    private static func prettyName(from hubID: String) -> String {
        let leaf = hubID.split(separator: "/").last.map(String.init) ?? hubID
        return leaf
            .replacingOccurrences(of: "-Instruct", with: "")
            .replacingOccurrences(of: "-instruct", with: "")
            .replacingOccurrences(of: "-4bit", with: " · 4-bit")
            .replacingOccurrences(of: "-8bit", with: " · 8-bit")
            .replacingOccurrences(of: "-3bit", with: " · 3-bit")
            .replacingOccurrences(of: "-2bit", with: " · 2-bit")
            .replacingOccurrences(of: "-", with: " ")
    }

    // MARK: - Static catalogs

    /// Hand-picked for iPhone-class RAM (≈ ≤ 3B 4-bit first).
    public static let recommended: [LocalMetalCatalogEntry] = [
        .init(hubID: "mlx-community/Llama-3.2-1B-Instruct-4bit", displayName: "Llama 3.2 1B", approxSize: "~0.7 GB", source: .recommended),
        .init(hubID: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B", approxSize: "~1.8 GB", source: .recommended),
        .init(hubID: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", displayName: "Qwen 2.5 1.5B", approxSize: "~0.9 GB", source: .recommended),
        .init(hubID: "mlx-community/Qwen3-0.6B-4bit", displayName: "Qwen 3 0.6B", approxSize: "~0.4 GB", source: .recommended),
        .init(hubID: "mlx-community/Qwen3-1.7B-4bit", displayName: "Qwen 3 1.7B", approxSize: "~1.0 GB", source: .recommended),
        .init(hubID: "mlx-community/gemma-2-2b-it-4bit", displayName: "Gemma 2 2B", approxSize: "~1.5 GB", source: .recommended),
        .init(hubID: "mlx-community/gemma-3-1b-it-qat-4bit", displayName: "Gemma 3 1B QAT", approxSize: "~0.8 GB", source: .recommended),
        .init(hubID: "mlx-community/Phi-3.5-mini-instruct-4bit", displayName: "Phi 3.5 Mini", approxSize: "~2.2 GB", source: .recommended),
        .init(hubID: "mlx-community/SmolLM-135M-Instruct-4bit", displayName: "SmolLM 135M", approxSize: "~0.1 GB", source: .recommended),
        .init(hubID: "mlx-community/LFM2-1.2B-4bit", displayName: "LFM2 1.2B", approxSize: "~0.7 GB", source: .recommended),
        .init(hubID: "mlx-community/granite-3.3-2b-instruct-4bit", displayName: "Granite 3.3 2B", approxSize: "~1.4 GB", source: .recommended),
        .init(hubID: "mlx-community/Qwen2.5-3B-Instruct-4bit", displayName: "Qwen 2.5 3B", approxSize: "~1.8 GB", source: .recommended),
    ]

    /// Models registered in mlx-swift-lm `LLMRegistry` (architectures supported by this stack).
    /// Source of truth: https://github.com/ml-explore/mlx-swift-lm (LLMModelFactory).
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
    ].map { hub in
        LocalMetalCatalogEntry(
            hubID: hub,
            displayName: prettyName(from: hub),
            approxSize: "",
            source: .mlxSwiftRegistry
        )
    }

    private struct HFModelRow: Decodable {
        let id: String
        let downloads: Int?
        let tags: [String]?
        let pipeline_tag: String?
    }
}
