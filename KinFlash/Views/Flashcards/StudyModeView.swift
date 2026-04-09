import SwiftUI
import GRDB

struct StudyModeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let deck: FlashcardDeck

    @State private var cards: [Flashcard] = []
    @State private var currentIndex = 0
    @State private var isFlipped = false
    @State private var filterMode: FlashcardStatus? = nil
    @State private var perspectiveName = ""

    var filteredCards: [Flashcard] {
        if let filter = filterMode {
            return cards.filter { $0.status == filter }
        }
        return cards
    }

    var currentCard: Flashcard? {
        guard currentIndex < filteredCards.count else { return nil }
        return filteredCards[currentIndex]
    }

    var progressCounts: (unknown: Int, learning: Int, known: Int) {
        (
            cards.filter { $0.status == .unknown }.count,
            cards.filter { $0.status == .learning }.count,
            cards.filter { $0.status == .known }.count
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            progressHeader

            if let card = currentCard {
                Spacer()
                cardView(card)
                Spacer()
                buttonRow(card)
            } else if filteredCards.isEmpty && !cards.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)
                    Text("All done!")
                        .font(.title2.bold())
                    Text("No cards match the current filter.")
                        .foregroundStyle(.secondary)
                    Button("Show All") { filterMode = nil; currentIndex = 0 }
                        .buttonStyle(.bordered)
                }
                Spacer()
            } else {
                Spacer()
                Text("No cards in this deck.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .navigationTitle("\(perspectiveName)'s Deck")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("All Cards") { filterMode = nil; currentIndex = 0 }
                    Button("Unknown Only") { filterMode = .unknown; currentIndex = 0 }
                    Button("Learning Only") { filterMode = .learning; currentIndex = 0 }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .onAppear(perform: loadCards)
    }

    // MARK: - Views

    private var progressHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Card \(currentIndex + 1) of \(filteredCards.count)")
                    .font(.caption)
                Spacer()
                HStack(spacing: 12) {
                    Label("\(progressCounts.unknown)", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Label("\(progressCounts.learning)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Label("\(progressCounts.known)", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal)

            GeometryReader { geo in
                let knownFraction = cards.isEmpty ? 0 : CGFloat(progressCounts.known) / CGFloat(cards.count)
                let learningFraction = cards.isEmpty ? 0 : CGFloat(progressCounts.learning) / CGFloat(cards.count)

                HStack(spacing: 0) {
                    Rectangle().fill(.green).frame(width: geo.size.width * knownFraction)
                    Rectangle().fill(.orange).frame(width: geo.size.width * learningFraction)
                    Rectangle().fill(.gray.opacity(0.2))
                }
            }
            .frame(height: 4)
            .clipShape(Capsule())
            .padding(.horizontal)
        }
        .padding(.top, 8)
    }

    private func cardView(_ card: Flashcard) -> some View {
        VStack(spacing: 20) {
            if isFlipped {
                Text(card.answer)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                if let explanation = card.explanation {
                    Text(explanation)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
            } else {
                Text(card.question)
                    .font(.title3)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 300)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.background)
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
        )
        .padding(.horizontal, 24)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                isFlipped.toggle()
            }
        }
        .overlay(alignment: .bottom) {
            if !isFlipped {
                Text("Tap to flip")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            }
        }
    }

    private func buttonRow(_ card: Flashcard) -> some View {
        HStack(spacing: 24) {
            Button {
                updateStatus(card, status: .unknown)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.red)
                    Text("Don't Know")
                        .font(.caption2)
                }
            }

            Button {
                updateStatus(card, status: .learning)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text("Learning")
                        .font(.caption2)
                }
            }

            Button {
                updateStatus(card, status: .known)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                    Text("Know It")
                        .font(.caption2)
                }
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: - Data

    private func loadCards() {
        guard let db = appState.databaseManager else { return }
        do {
            cards = try db.dbQueue.read { database in
                try Flashcard.filter(Column("deckId") == deck.id).fetchAll(database)
            }
            let person = try db.dbQueue.read { database in
                try Person.fetchOne(database, key: deck.perspectivePersonId)
            }
            perspectiveName = person?.firstName ?? "Unknown"
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func updateStatus(_ card: Flashcard, status: FlashcardStatus) {
        guard let db = appState.databaseManager else { return }
        do {
            try db.dbQueue.write { database in
                var updated = card
                updated.status = status
                updated.lastReviewedAt = Date()
                try updated.update(database)
            }

            if let idx = cards.firstIndex(where: { $0.id == card.id }) {
                cards[idx].status = status
                cards[idx].lastReviewedAt = Date()
            }

            isFlipped = false
            if currentIndex < filteredCards.count - 1 {
                withAnimation {
                    currentIndex += 1
                }
            } else {
                currentIndex = 0
            }
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}
