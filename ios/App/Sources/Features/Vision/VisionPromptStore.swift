import Foundation

/// A reusable Vision capture instruction the user can apply before shooting.
struct VisionPromptPreset: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var title: String
    var prompt: String
    /// Seeded app defaults — can be edited but restored via “Reset built-ins”.
    var isBuiltIn: Bool
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
    }
}

/// Persists Vision prompt presets in `UserDefaults`.
@MainActor
final class VisionPromptStore: ObservableObject {
    static let shared = VisionPromptStore()

    static let storageKey = "vision.promptPresets.v1"

    @Published private(set) var presets: [VisionPromptPreset] = []

    private init() {
        load()
    }

    // MARK: - Built-in seeds

    /// Default capture behavior (empty prompt → generic analysis in the model).
    static let defaultPresetID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!

    static var builtInPresets: [VisionPromptPreset] {
        [
            VisionPromptPreset(
                id: defaultPresetID,
                title: "General analysis",
                prompt: "",
                isBuiltIn: true,
                sortOrder: 0
            ),
            VisionPromptPreset(
                id: UUID(uuidString: "B2C3D4E5-F6A7-8901-BCDE-F12345678901")!,
                title: "Transcribe text",
                prompt: """
                Transcribe all readable text in this photo.

                ## Transcript
                Put the full transcription first, preserving layout with line breaks where helpful.

                ## Notes
                Only after the transcript: note anything partially obscured, uncertain, or unreadable. Do not invent text that is not visible.
                """,
                isBuiltIn: true,
                sortOrder: 1
            ),
            VisionPromptPreset(
                id: UUID(uuidString: "C3D4E5F6-A7B8-9012-CDEF-123456789012")!,
                title: "Identify objects",
                prompt: """
                Identify what is in this photo.

                ## Answer
                Lead with a short inventory of the main objects, brands, products, and materials (bullets).

                ## Details
                For each item, add useful detail only if needed (color, condition, type). Mark guesses clearly.
                """,
                isBuiltIn: true,
                sortOrder: 2
            ),
            VisionPromptPreset(
                id: UUID(uuidString: "D4E5F6A7-B8C9-0123-DEF0-234567890123")!,
                title: "Quiz / homework",
                prompt: """
                This photo shows a question, worksheet, or homework problem.

                Structure your reply exactly like this:

                ## Final answer
                Put the final answer(s) first — clear, boxed-style if useful. If multiple questions, list each answer first.

                ## Question(s)
                Briefly restate or extract the question(s) from the image.

                ## Reasoning
                Show steps and reasoning below the fold (after the final answer). Keep it concise.

                If the image is incomplete, still give the best answer you can and say what is missing after the answer.
                Do not open with a description of the photo.
                """,
                isBuiltIn: true,
                sortOrder: 3
            ),
            VisionPromptPreset(
                id: UUID(uuidString: "E5F6A7B8-C9D0-1234-EF01-345678901234")!,
                title: "Accessibility",
                prompt: """
                Write a clear accessibility description for someone who cannot see this photo.

                ## Summary
                One short sentence with the essential subject and setting first.

                ## Details
                Then cover important text, colors, spatial layout, and secondary elements. Be concise but complete.
                """,
                isBuiltIn: true,
                sortOrder: 4
            ),
            VisionPromptPreset(
                id: UUID(uuidString: "F6A7B8C9-D0E1-2345-F012-456789012345")!,
                title: "Safety check",
                prompt: """
                Assess practical hazards or safety issues in this photo.

                ## Findings
                Lead with the risk list by severity (or “No obvious hazards” if clear).

                ## Next steps
                Suggest simple actions when relevant.

                Do not open with a general description of the scene.
                """,
                isBuiltIn: true,
                sortOrder: 5
            ),
        ]
    }

    // MARK: - Mutations

    func apply(_ presets: [VisionPromptPreset]) {
        self.presets = Self.normalized(presets)
        persist()
    }

    @discardableResult
    func add(title: String, prompt: String) -> VisionPromptPreset {
        let nextOrder = (presets.map(\.sortOrder).max() ?? -1) + 1
        let preset = VisionPromptPreset(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: false,
            sortOrder: nextOrder
        )
        presets.append(preset)
        presets = Self.normalized(presets)
        persist()
        return preset
    }

    func update(_ preset: VisionPromptPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var copy = preset
        copy.title = copy.title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.prompt = copy.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        presets[idx] = copy
        presets = Self.normalized(presets)
        persist()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        // Keep at least the default built-in.
        if !presets.contains(where: { $0.id == Self.defaultPresetID }) {
            presets.insert(Self.builtInPresets[0], at: 0)
        }
        presets = Self.normalized(presets)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        var list = presets
        list.move(fromOffsets: source, toOffset: destination)
        for i in list.indices {
            list[i].sortOrder = i
        }
        presets = list
        persist()
    }

    /// Restore missing built-ins and refresh product prompt copy without wiping user presets.
    func restoreBuiltIns() {
        var byID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        for builtIn in Self.builtInPresets {
            // Always refresh known built-in copy so “answer first” prompts ship.
            byID[builtIn.id] = builtIn
        }
        presets = Self.normalized(Array(byID.values))
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([VisionPromptPreset].self, from: data),
              !decoded.isEmpty
        else {
            presets = Self.normalized(Self.builtInPresets)
            persist()
            return
        }
        // Refresh built-in titles/prompts (e.g. answer-first structure) while
        // keeping custom user presets intact.
        let seeds = Dictionary(uniqueKeysWithValues: Self.builtInPresets.map { ($0.id, $0) })
        var merged = decoded
        for i in merged.indices {
            if merged[i].isBuiltIn, let seed = seeds[merged[i].id] {
                merged[i].title = seed.title
                merged[i].prompt = seed.prompt
                merged[i].isBuiltIn = true
            }
        }
        for seed in Self.builtInPresets where !merged.contains(where: { $0.id == seed.id }) {
            merged.append(seed)
        }
        presets = Self.normalized(merged)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func normalized(_ list: [VisionPromptPreset]) -> [VisionPromptPreset] {
        list
            .sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            .enumerated()
            .map { index, preset in
                var p = preset
                p.sortOrder = index
                return p
            }
    }
}
