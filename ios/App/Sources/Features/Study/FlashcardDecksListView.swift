import SwiftUI

/// Study mode home: a big "Scan questions" entry plus the saved flashcard decks.
struct FlashcardDecksListView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var store = FlashcardDeckStore.shared

    @State private var showScanner = false
    @State private var showGuided = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    scanCTA
                    guidedCTA

                    if store.sortedDecks.isEmpty {
                        emptyDecks
                    } else {
                        decksSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Study")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showScanner) {
            StudyScanView()
                .environmentObject(state)
        }
        .fullScreenCover(isPresented: $showGuided) {
            GuidedLearningView()
                .environmentObject(state)
        }
    }

    // MARK: - Scan CTA

    private var scanCTA: some View {
        Button {
            showScanner = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.background)
                    .frame(width: 52, height: 52)
                    .background(Theme.inkOnAccent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Scan questions")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.background)
                    Text("Snap a page of questions to extract Q&A cards")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.background.opacity(0.75))
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.background)
            }
            .padding(18)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan questions into a flashcard deck")
    }

    // MARK: - Guided Learning CTA

    private var guidedCTA: some View {
        Button {
            showGuided = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52)
                    .background(Theme.accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Guided learning")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("A tutor teaches step by step, with check-ins and hints")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(18)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.separator.opacity(0.8), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start a guided learning lesson")
    }

    // MARK: - Decks

    private var decksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Decks")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)

            LazyVStack(spacing: 12) {
                ForEach(store.sortedDecks) { deck in
                    NavigationLink(value: RootRoute.studyDeck(deck.id)) {
                        deckCard(deck)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func deckCard(_ deck: FlashcardDeck) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(deck.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(deck.cards.count) card\(deck.cards.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text("·")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    Text(deck.updatedAt, style: .relative)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.separator.opacity(0.7), lineWidth: 1)
        }
    }

    private var emptyDecks: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("No decks yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Scan a page of questions and save the cards — they'll appear here.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }
}

/// Opens a saved deck: editable flashcards that persist on change.
struct FlashcardDeckDetailView: View {
    @ObservedObject var store: FlashcardDeckStore = .shared
    let deckID: UUID

    @State private var deck: FlashcardDeck = FlashcardDeck(title: "")
    @State private var showRename = false
    @State private var renameTitle = ""

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(Array(deck.sortedCards.enumerated()), id: \.element.id) { index, card in
                    StudyFlashcardCardView(
                        index: index + 1,
                        question: textBinding(for: card.id, keyPath: \.question),
                        answer: textBinding(for: card.id, keyPath: \.answer),
                        reasoning: textBinding(for: card.id, keyPath: \.reasoning),
                        saveState: .saved,
                        showsSaveButton: false,
                        onEdit: {
                            persist()
                        },
                        onDelete: {
                            deck.cards.removeAll { $0.id == card.id }
                            persist()
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(deck.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    renameTitle = deck.title
                    showRename = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .accessibilityLabel("Rename deck")
            }
        }
        .onAppear {
            loadDeck()
        }
        .onChange(of: deckID) { _, _ in
            loadDeck()
        }
        .alert("Rename deck", isPresented: $showRename) {
            TextField("Deck name", text: $renameTitle)
            Button("Save") {
                store.renameDeck(id: deckID, title: renameTitle)
                loadDeck()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this deck a name you'll recognize.")
        }
    }

    private func loadDeck() {
        if let found = store.deck(withID: deckID) {
            deck = found
        }
    }

    private func persist() {
        store.upsertDeck(deck)
    }

    private func textBinding(
        for id: UUID,
        keyPath: WritableKeyPath<Flashcard, String>
    ) -> Binding<String> {
        Binding(
            get: {
                deck.cards.first(where: { $0.id == id })?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                guard let idx = deck.cards.firstIndex(where: { $0.id == id }) else { return }
                deck.cards[idx][keyPath: keyPath] = newValue
            }
        )
    }
}
