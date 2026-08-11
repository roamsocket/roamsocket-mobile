import Foundation
import SwiftUI

/// A single saved flashcard (question + answer + reasoning).
struct Flashcard: Identifiable, Codable, Hashable {
    let id: UUID
    var question: String
    var answer: String
    var reasoning: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        reasoning: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.reasoning = reasoning
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A deck of flashcards. One Study scan session saves every scanned page
/// into a single deck.
struct FlashcardDeck: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var cards: [Flashcard]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        cards: [Flashcard] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cards = cards
    }

    /// Cards in scan order (oldest first).
    var sortedCards: [Flashcard] {
        cards.sorted { $0.createdAt < $1.createdAt }
    }
}

/// Persists flashcard decks in UserDefaults (local-only, like Artifacts).
final class FlashcardDeckStore: ObservableObject {
    static let shared = FlashcardDeckStore()

    @Published private(set) var decks: [FlashcardDeck] = []
    private let storageKey = "flashcardDecks.v1"

    init() {
        load()
    }

    /// Decks newest-activity first.
    var sortedDecks: [FlashcardDeck] {
        decks.sorted { $0.updatedAt > $1.updatedAt }
    }

    func deck(withID id: UUID) -> FlashcardDeck? {
        decks.first(where: { $0.id == id })
    }

    /// Insert or replace a deck by id. Touches `updatedAt` so it bubbles to
    /// the top of the list when cards are added or edited.
    @discardableResult
    func upsertDeck(_ deck: FlashcardDeck) -> FlashcardDeck {
        var updated = deck
        updated.updatedAt = Date()
        if let idx = decks.firstIndex(where: { $0.id == deck.id }) {
            decks[idx] = updated
        } else {
            decks.insert(updated, at: 0)
        }
        save()
        return updated
    }

    func renameDeck(id: UUID, title: String) {
        guard let idx = decks.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        decks[idx].title = trimmed
        decks[idx].updatedAt = Date()
        save()
    }

    func deleteDeck(id: UUID) {
        decks.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        decks.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FlashcardDeck].self, from: data)
        else { return }
        decks = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(decks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
