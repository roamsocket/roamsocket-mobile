import Foundation
import Combine

/// Structured user memory (Settings → Memory), private on device.
/// Mirrors desktop `UserMemoryStore`: You / Topics / Areas, freeform add,
/// detail edit, and import paste from another AI provider.
@MainActor
final class UserMemoryStore: ObservableObject {
    static let shared = UserMemoryStore()

    enum Category: String, Codable, CaseIterable, Identifiable {
        case you
        case topic
        case area

        var id: String { rawValue }

        var label: String {
            switch self {
            case .you: return "You"
            case .topic: return "Topics"
            case .area: return "Areas"
            }
        }

        static let displayOrder: [Category] = [.you, .topic, .area]
    }

    struct Entry: Identifiable, Codable, Equatable, Hashable {
        var id: String
        var category: Category
        var title: String
        var summary: String
        var details: [String]
        var updatedAt: Date
    }

    @Published private(set) var entries: [Entry] = []

    private let key = "userMemory.entries.v1"

    /// Prompt users copy into another AI product when importing memory.
    static let importPrompt = """
    Export all of my stored memories and any context you've learned about me from past conversations. Preserve my words verbatim where possible, especially for instructions and preferences.

    ## Categories (output in this order):

    ### You — Profile
    - Summary line
    - Bullet details (name, role, location, preferences)

    ### Topics
    One section per interest/topic with a short summary and bullets.

    ### Areas
    One section per project/product/domain with a short summary and bullets.
    """

    private init() { load() }

    var isEmpty: Bool { entries.isEmpty }

    func list() -> [Entry] {
        entries.sorted { $0.updatedAt > $1.updatedAt }
    }

    func byCategory(_ category: Category) -> [Entry] {
        list().filter { $0.category == category }
    }

    func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    @discardableResult
    func upsert(
        id: String? = nil,
        category: Category,
        title: String,
        summary: String,
        details: [String]
    ) -> Entry {
        let now = Date()
        if let id, let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].category = category
            entries[idx].title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? entries[idx].title
                : title.trimmingCharacters(in: .whitespacesAndNewlines)
            entries[idx].summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            entries[idx].details = details
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            entries[idx].updatedAt = now
            save()
            return entries[idx]
        }
        let entry = Entry(
            id: id ?? "mem_\(UUID().uuidString.prefix(8).lowercased())",
            category: category,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled"
                : title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            details: details
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            updatedAt: now
        )
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    func delete(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    @discardableResult
    func addFreeformFact(_ text: String) -> Entry? {
        let fact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else { return nil }
        let bullet = fact.prefix(1).uppercased() + fact.dropFirst()
        if var profile = byCategory(.you).first(where: { $0.title.lowercased() == "profile" }) {
            if !profile.details.contains(where: { $0.caseInsensitiveCompare(String(bullet)) == .orderedSame }) {
                profile.details.append(String(bullet))
            }
            if profile.summary.isEmpty {
                profile.summary = String(bullet.prefix(80))
            }
            profile.updatedAt = Date()
            if let idx = entries.firstIndex(where: { $0.id == profile.id }) {
                entries[idx] = profile
            }
            save()
            return profile
        }
        return upsert(
            category: .you,
            title: "Profile",
            summary: String(bullet.prefix(80)),
            details: [String(bullet)]
        )
    }

    @discardableResult
    func applyEntryCommand(id: String, command: String) -> Entry? {
        guard var entry = entry(id: id) else { return nil }
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return entry }
        let lower = cmd.lowercased()

        if lower.hasPrefix("forget ") || lower.hasPrefix("remove ") || lower.hasPrefix("delete ") {
            let topic = cmd
                .replacingOccurrences(of: #"^(forget|remove|delete)\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !topic.isEmpty {
                let next = entry.details.filter { !$0.localizedCaseInsensitiveContains(topic) }
                if next.count != entry.details.count {
                    entry.details = next
                } else {
                    entry.details.append("Note: user asked to forget “\(topic)”.")
                }
                if entry.summary.localizedCaseInsensitiveContains(topic) {
                    entry.summary = next.first ?? entry.summary
                }
            }
        } else if let range = lower.range(of: #"^(change|set) summary to\s+"#, options: .regularExpression) {
            let drop = cmd.distance(from: cmd.startIndex, to: range.upperBound)
            entry.summary = String(cmd.dropFirst(drop)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if lower.hasPrefix("rename to ") {
            let name = String(cmd.dropFirst("rename to ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { entry.title = name }
        } else {
            var fact = cmd
            if let r = fact.range(of: #"^remember that(?: i)?\s+"#, options: [.regularExpression, .caseInsensitive]) {
                fact = String(fact[r.upperBound...])
            } else if fact.lowercased().hasPrefix("remember ") {
                fact = String(fact.dropFirst("remember ".count))
            } else if fact.lowercased().hasPrefix("add ") {
                fact = String(fact.dropFirst("add ".count))
            }
            fact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fact.isEmpty else { return entry }
            let bullet = fact.prefix(1).uppercased() + fact.dropFirst()
            // Smart: if there's a single fact, treat the command as a replacement
            // (matches "tell the assistant what to change"). If there are already
            // multiple facts, append the new one as another bullet.
            if entry.details.count <= 1 {
                entry.details = [String(bullet)]
                if entry.summary.isEmpty
                    || entry.summary.caseInsensitiveCompare(entry.details.first ?? "")
                        != .orderedSame {
                    entry.summary = String(bullet.prefix(80))
                }
            } else if !entry.details.contains(where: { $0.caseInsensitiveCompare(String(bullet)) == .orderedSame }) {
                entry.details.append(String(bullet))
            }
        }
        entry.updatedAt = Date()
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        }
        save()
        return entry
    }

    @discardableResult
    func importFromText(_ raw: String) -> Int {
        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }

        let blocks = Self.splitImportBlocks(text)
        if blocks.isEmpty {
            let lines = text
                .components(separatedBy: .newlines)
                .map { $0.replacingOccurrences(of: #"^[-*•]\s+"#, with: "", options: .regularExpression) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            upsert(
                category: .you,
                title: "Imported",
                summary: String(text.prefix(100)).replacingOccurrences(of: "\n", with: " "),
                details: Array(lines.prefix(40))
            )
            return 1
        }
        for block in blocks {
            upsert(
                category: block.category,
                title: block.title,
                summary: block.summary,
                details: block.details
            )
        }
        return blocks.count
    }

    /// System prompt blob for chat injection.
    func formatForSystem() -> String {
        var parts: [String] = []
        for cat in Category.displayOrder {
            let items = byCategory(cat)
            guard !items.isEmpty else { continue }
            parts.append("## \(cat.label)")
            for e in items {
                parts.append("### \(e.title)")
                if !e.summary.isEmpty { parts.append(e.summary) }
                for d in e.details { parts.append("- \(d)") }
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            entries = []
            return
        }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
        objectWillChange.send()
    }

    // MARK: - Import parse

    private struct ImportBlock {
        var category: Category
        var title: String
        var summary: String
        var details: [String]
    }

    private static func splitImportBlocks(_ text: String) -> [ImportBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [ImportBlock] = []
        var category: Category = .you
        var title = ""
        var summary = ""
        var details: [String] = []
        var sawHeading = false

        func flush() {
            guard !title.isEmpty || !details.isEmpty || !summary.isEmpty else { return }
            blocks.append(ImportBlock(
                category: category,
                title: title.isEmpty ? (category == .you ? "Profile" : "Untitled") : title,
                summary: summary.isEmpty ? (details.first ?? "") : summary,
                details: details.isEmpty ? (summary.isEmpty ? [] : [summary]) : details
            ))
            title = ""
            summary = ""
            details = []
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let catMatch = line.range(
                of: #"^(?:#{1,3}\s*)?(You|Topics?|Areas?)\b(?:\s*[—–:-]\s*(.+))?$"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                flush()
                sawHeading = true
                let matched = String(line[catMatch])
                let label = matched.lowercased()
                if label.contains("topic") { category = .topic }
                else if label.contains("area") { category = .area }
                else { category = .you }

                if let restRange = matched.range(of: #"[—–:-]\s*(.+)$"#, options: .regularExpression) {
                    var rest = String(matched[restRange])
                    rest = rest.replacingOccurrences(of: #"^[—–:-]\s*"#, with: "", options: .regularExpression)
                    if !rest.isEmpty { title = rest }
                    else if category == .you { title = "Profile" }
                } else if category == .you {
                    title = "Profile"
                }
                continue
            }

            if let h = line.range(of: #"^#{1,3}\s+(.+)$"#, options: .regularExpression) {
                flush()
                sawHeading = true
                title = String(line[h])
                    .replacingOccurrences(of: #"^#{1,3}\s+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if category == .you && !title.localizedCaseInsensitiveContains("profile") {
                    if title.range(of: #"app|project|product|startup|company|kind|work"#, options: [.regularExpression, .caseInsensitive]) != nil {
                        category = .area
                    } else if title.range(of: #"name|role|location|bio"#, options: [.regularExpression, .caseInsensitive]) == nil {
                        category = .topic
                    }
                }
                continue
            }

            let bullet = line
                .replacingOccurrences(of: #"^[-*•]\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
            if bullet != line || line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("•") {
                details.append(bullet.trimmingCharacters(in: .whitespacesAndNewlines))
                continue
            }

            if summary.isEmpty {
                summary = line
            } else {
                details.append(line)
            }
        }
        flush()
        return sawHeading ? blocks : []
    }
}

extension UserMemoryStore.Entry {
    var relativeUpdated: String {
        let diff = Date().timeIntervalSince(updatedAt)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 172_800 { return "\(Int(diff / 3600))h ago" }
        if diff < 1_209_600 { return "\(Int(diff / 86_400))d ago" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: updatedAt)
    }
}
