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

    /// One row in the activity log: a single mutation the user can undo.
    /// The `before` snapshot lets us restore a prior `details` / `summary`
    /// when the user undoes an `add` or `update`; `new` lets us delete the
    /// entry that was just created. `source` distinguishes auto-save (from
    /// chat) from explicit edits (manage screen / detail sheet).
    struct ActivityEntry: Identifiable, Codable, Equatable, Hashable {
        var id: String
        var timestamp: Date
        var kind: Kind
        var entryID: String
        var entryTitle: String
        var detailPreview: String
        var before: Entry?
        var after: Entry?
        var source: Source

        enum Kind: String, Codable {
            case add
            case update
            case forget
            case rename
        }

        enum Source: String, Codable {
            case chatAutoSave = "chat"
            case userEdit = "user"
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var activity: [ActivityEntry] = []

    private let key = "userMemory.entries.v1"
    private let activityKey = "userMemory.activity.v1"
    private let activityMaxAge: TimeInterval = 60 * 60 * 24 * 30 // 30 days
    private let activityMaxCount = 200

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

    private init() {
        load()
        pruneActivity()
    }

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

    /// Recent activity rows, newest first. Caller can filter by source.
    func activityList(source: ActivityEntry.Source? = nil, limit: Int = 50) -> [ActivityEntry] {
        let pool = source.map { s in activity.filter { $0.source == s } } ?? activity
        return Array(pool.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
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
        guard let entry = entry(id: id) else { return nil }
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return entry }
        let kind = classifyCommand(cmd)
        let updated = mutateEntry(entry: entry, kind: kind, command: cmd)
        guard let updated, updated != entry else { return entry }
        return commitMutation(
            kind: activityKind(for: kind),
            before: entry,
            after: updated,
            source: .userEdit
        )
    }

    /// Apply a structured action parsed from a chat reply. Returns the
    /// resulting entry, or nil if the action was a no-op.
    @discardableResult
    func applyAction(_ action: ParsedAction) -> Entry? {
        switch action {
        case let .add(category, title, summary, details):
            // Match by title within the same category; create if missing.
            let target = entry(forTitle: title, category: category)
            if var target {
                let before = target
                let newDetails = details
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let combined = mergeDetails(existing: target.details, adding: newDetails)
                if combined == target.details && (summary.isEmpty || summary == target.summary) {
                    return target
                }
                target.details = combined
                if !summary.isEmpty { target.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines) }
                target.updatedAt = Date()
                return commitMutation(
                    kind: .update,
                    before: before,
                    after: target,
                    source: .chatAutoSave
                )
            } else {
                let created = upsert(
                    category: category,
                    title: title,
                    summary: summary,
                    details: details
                )
                recordActivity(kind: .add, before: nil, after: created, source: .chatAutoSave)
                return created
            }
        case let .forget(target):
            guard let victim = entry(forTitleOrContains: target) else { return nil }
            let before = victim
            let next = victim.details.filter { !$0.localizedCaseInsensitiveContains(target) }
            if next.count == victim.details.count { return nil }
            var updated = victim
            updated.details = next
            updated.updatedAt = Date()
            return commitMutation(
                kind: .forget,
                before: before,
                after: updated,
                source: .chatAutoSave
            )
        case let .rename(target, value):
            guard let victim = entry(forTitleOrContains: target) else { return nil }
            let before = victim
            var updated = victim
            updated.title = value
            updated.updatedAt = Date()
            return commitMutation(
                kind: .rename,
                before: before,
                after: updated,
                source: .chatAutoSave
            )
        case let .setSummary(target, value):
            guard let victim = entry(forTitleOrContains: target) else { return nil }
            let before = victim
            var updated = victim
            updated.summary = value
            updated.updatedAt = Date()
            return commitMutation(
                kind: .update,
                before: before,
                after: updated,
                source: .chatAutoSave
            )
        case let .setDetails(target, value):
            guard let victim = entry(forTitleOrContains: target) else { return nil }
            let before = victim
            var updated = victim
            updated.details = value
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            updated.updatedAt = Date()
            return commitMutation(
                kind: .update,
                before: before,
                after: updated,
                source: .chatAutoSave
            )
        }
    }

    /// Structured action emitted by the chat parser. Mirrors the desktop
    /// `MemoryAction` union minus the wire-format-specific details.
    enum ParsedAction: Equatable {
        case add(category: Category, title: String, summary: String, details: [String])
        case forget(target: String)
        case rename(target: String, value: String)
        case setSummary(target: String, value: String)
        case setDetails(target: String, value: [String])
    }

    // MARK: - Private mutation helpers

    private enum CommandKind {
        case forget(topic: String)
        case setSummary(value: String)
        case rename(value: String)
        case appendOrReplaceFact(fact: String)
    }

    private func classifyCommand(_ cmd: String) -> CommandKind {
        let lower = cmd.lowercased()
        if lower.hasPrefix("forget ") || lower.hasPrefix("remove ") || lower.hasPrefix("delete ") {
            let topic = cmd
                .replacingOccurrences(of: #"^(forget|remove|delete)\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .forget(topic: topic)
        }
        if let range = lower.range(of: #"^(change|set) summary to\s+"#, options: .regularExpression) {
            let drop = cmd.distance(from: cmd.startIndex, to: range.upperBound)
            return .setSummary(value: String(cmd.dropFirst(drop)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if lower.hasPrefix("rename to ") {
            let name = String(cmd.dropFirst("rename to ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return .rename(value: name)
        }
        var fact = cmd
        if let r = fact.range(of: #"^remember that(?: i)?\s+"#, options: [.regularExpression, .caseInsensitive]) {
            fact = String(fact[r.upperBound...])
        } else if fact.lowercased().hasPrefix("remember ") {
            fact = String(fact.dropFirst("remember ".count))
        } else if fact.lowercased().hasPrefix("add ") {
            fact = String(fact.dropFirst("add ".count))
        }
        return .appendOrReplaceFact(fact: fact.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func mutateEntry(entry: Entry, kind: CommandKind, command: String) -> Entry? {
        var entry = entry
        switch kind {
        case let .forget(topic):
            guard !topic.isEmpty else { return nil }
            let next = entry.details.filter { !$0.localizedCaseInsensitiveContains(topic) }
            if next.count == entry.details.count { return nil }
            entry.details = next
            if entry.summary.localizedCaseInsensitiveContains(topic) {
                entry.summary = next.first ?? entry.summary
            }
        case let .setSummary(value):
            entry.summary = value
        case let .rename(value):
            guard !value.isEmpty else { return nil }
            entry.title = value
        case let .appendOrReplaceFact(fact):
            guard !fact.isEmpty else { return nil }
            let bullet = fact.prefix(1).uppercased() + fact.dropFirst()
            if entry.details.count <= 1 {
                entry.details = [String(bullet)]
                if entry.summary.isEmpty
                    || entry.summary.caseInsensitiveCompare(entry.details.first ?? "") != .orderedSame {
                    entry.summary = String(bullet.prefix(80))
                }
            } else if !entry.details.contains(where: { $0.caseInsensitiveCompare(String(bullet)) == .orderedSame }) {
                entry.details.append(String(bullet))
            } else {
                return nil // duplicate fact
            }
        }
        entry.updatedAt = Date()
        return entry
    }

    private func activityKind(for kind: CommandKind) -> ActivityEntry.Kind {
        switch kind {
        case .forget: return .forget
        case .rename: return .rename
        case .setSummary, .appendOrReplaceFact: return .update
        }
    }

    private func commitMutation(
        kind: ActivityEntry.Kind,
        before: Entry,
        after: Entry,
        source: ActivityEntry.Source
    ) -> Entry {
        if let idx = entries.firstIndex(where: { $0.id == after.id }) {
            entries[idx] = after
        } else {
            entries.insert(after, at: 0)
        }
        save()
        recordActivity(kind: kind, before: before, after: after, source: source)
        return after
    }

    private func entry(forTitle title: String, category: Category) -> Entry? {
        let lower = title.lowercased()
        return entries.first { $0.category == category && $0.title.lowercased() == lower }
    }

    private func entry(forTitleOrContains needle: String) -> Entry? {
        let lower = needle.lowercased()
        if let exact = entries.first(where: { $0.title.lowercased() == lower }) {
            return exact
        }
        return entries.first { $0.details.contains(where: { $0.lowercased().contains(lower) }) }
            ?? entries.first { $0.summary.lowercased().contains(lower) }
    }

    private func mergeDetails(existing: [String], adding: [String]) -> [String] {
        var out = existing
        for d in adding {
            if !out.contains(where: { $0.caseInsensitiveCompare(d) == .orderedSame }) {
                out.append(d)
            }
        }
        return out
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
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
        if let data = UserDefaults.standard.data(forKey: activityKey),
           let decoded = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
            activity = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
        objectWillChange.send()
    }

    private func saveActivity() {
        if let data = try? JSONEncoder().encode(activity) {
            UserDefaults.standard.set(data, forKey: activityKey)
        }
    }

    private func pruneActivity() {
        let cutoff = Date().addingTimeInterval(-activityMaxAge)
        let kept = activity.filter { $0.timestamp >= cutoff }
        let trimmed = kept.count > activityMaxCount
            ? Array(kept.suffix(activityMaxCount))
            : kept
        if trimmed.count != activity.count {
            activity = trimmed
            saveActivity()
        }
    }

    // MARK: - Activity log

    /// Record a mutation so the user can see and undo it. `source` is
    /// `.userEdit` for explicit manage-screen edits and `.chatAutoSave` for
    /// tags parsed from a chat reply.
    func recordActivity(
        kind: ActivityEntry.Kind,
        before: Entry?,
        after: Entry?,
        source: ActivityEntry.Source
    ) {
        let id = "act_\(UUID().uuidString.prefix(8).lowercased())"
        let previewEntry = after ?? before
        let preview = previewEntry?.summary.isEmpty == false
            ? previewEntry!.summary
            : (previewEntry?.details.first ?? previewEntry?.title ?? "")
        let entry = ActivityEntry(
            id: id,
            timestamp: Date(),
            kind: kind,
            entryID: after?.id ?? before?.id ?? "",
            entryTitle: previewEntry?.title ?? "",
            detailPreview: preview,
            before: before,
            after: after,
            source: source
        )
        activity.append(entry)
        if activity.count > activityMaxCount {
            activity = Array(activity.suffix(activityMaxCount))
        }
        saveActivity()
    }

    /// Undo a single activity row. Returns true on success. For every kind,
    /// restoring the entry means putting back the `before` snapshot. For
    /// `add` (where there is no `before`), the entry is removed entirely.
    @discardableResult
    func undoActivity(id: String) -> Bool {
        guard let idx = activity.firstIndex(where: { $0.id == id }) else { return false }
        let row = activity[idx]
        if let before = row.before {
            if let eidx = entries.firstIndex(where: { $0.id == before.id }) {
                entries[eidx] = before
            } else {
                entries.insert(before, at: 0)
            }
        } else {
            entries.removeAll { $0.id == row.entryID }
        }
        activity.remove(at: idx)
        save()
        saveActivity()
        return true
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
