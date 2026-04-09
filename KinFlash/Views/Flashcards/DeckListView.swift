import SwiftUI
import GRDB

struct DeckListView: View {
    @Environment(AppState.self) private var appState
    @State private var decks: [DeckInfo] = []
    @State private var selectedDeck: FlashcardDeck?

    struct DeckInfo: Identifiable {
        let deck: FlashcardDeck
        let perspectiveName: String
        let unknown: Int
        let learning: Int
        let known: Int
        var id: UUID { deck.id }
    }

    var body: some View {
        List {
            if decks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No Flashcard Decks")
                        .font(.headline)
                    Text("Generate flashcards from any person's profile to start studying.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                ForEach(decks) { info in
                    Button {
                        selectedDeck = info.deck
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(info.perspectiveName)'s Deck")
                                    .font(.headline)
                                Spacer()
                                Text("\(info.deck.cardCount) cards")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 16) {
                                Label("\(info.unknown)", systemImage: "questionmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                Label("\(info.learning)", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Label("\(info.known)", systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }

                            Text("Generated \(info.deck.generatedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete(perform: deleteDeck)
            }
        }
        .navigationTitle("Flashcard Decks")
        .onAppear(perform: loadDecks)
        .sheet(item: $selectedDeck) { deck in
            NavigationStack {
                StudyModeView(deck: deck)
            }
        }
    }

    private func loadDecks() {
        guard let db = appState.databaseManager else { return }
        do {
            let allDecks = try db.dbQueue.read { database in
                try FlashcardDeck.order(Column("generatedAt").desc).fetchAll(database)
            }
            decks = try allDecks.map { deck in
                let cards = try db.dbQueue.read { database in
                    try Flashcard.filter(Column("deckId") == deck.id).fetchAll(database)
                }
                let person = try db.dbQueue.read { database in
                    try Person.fetchOne(database, key: deck.perspectivePersonId)
                }
                return DeckInfo(
                    deck: deck,
                    perspectiveName: person?.firstName ?? "Unknown",
                    unknown: cards.filter { $0.status == .unknown }.count,
                    learning: cards.filter { $0.status == .learning }.count,
                    known: cards.filter { $0.status == .known }.count
                )
            }
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func deleteDeck(at offsets: IndexSet) {
        guard let db = appState.databaseManager else { return }
        for index in offsets {
            let deckId = decks[index].deck.id
            do {
                try db.dbQueue.write { database in
                    _ = try FlashcardDeck.deleteOne(database, key: deckId)
                }
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
        decks.remove(atOffsets: offsets)
    }
}

extension FlashcardDeck: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: FlashcardDeck, rhs: FlashcardDeck) -> Bool { lhs.id == rhs.id }
}
