import SwiftUI

struct FlashcardGenerationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let person: Person

    @State private var cards: [GeneratedFlashcard] = []
    @State private var isGenerating = false
    @State private var isGenerated = false
    @State private var errorMessage: String?
    @State private var savedDeck: FlashcardDeck?
    @State private var showStudyMode = false

    var body: some View {
        VStack(spacing: 24) {
            if !isGenerated {
                preGenerationView
            } else {
                postGenerationView
            }
        }
        .padding()
        .navigationTitle("Generate Flashcards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .sheet(isPresented: $showStudyMode) {
            if let deck = savedDeck {
                NavigationStack {
                    StudyModeView(deck: deck)
                }
            }
        }
    }

    private var preGenerationView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 50))
                .foregroundStyle(.purple)

            Text("Generate Flashcards")
                .font(.title2.bold())

            Text("for \(person.displayName)")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("From \(person.firstName)'s perspective, we'll generate questions about family relationships.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            HStack(spacing: 32) {
                VStack {
                    Text("\(appState.people.count)")
                        .font(.title.bold())
                    Text("People")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text("~\(max(appState.people.count - 1, 0))")
                        .font(.title.bold())
                    Text("Est. Cards")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isGenerating {
                ProgressView("Generating...")
            } else {
                Button(action: generate) {
                    Label("Generate", systemImage: "sparkles")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.purple)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }

            if let error = errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
    }

    private var postGenerationView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.green)

            Text("\(cards.count) Cards Generated!")
                .font(.title2.bold())

            // Preview some cards
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Q: \(card.question)")
                                .font(.subheadline.bold())
                            Text("A: \(card.answer)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            HStack(spacing: 16) {
                Button(action: saveDeck) {
                    Label("Save & Study", systemImage: "rectangle.stack")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private func generate() {
        guard let db = appState.databaseManager else { return }
        isGenerating = true
        errorMessage = nil

        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let generator = FlashcardGenerator(dbQueue: db.dbQueue, resolver: resolver)

        do {
            cards = try generator.generate(perspectivePersonId: person.id)
            isGenerated = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isGenerating = false
    }

    private func saveDeck() {
        guard let db = appState.databaseManager else { return }
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let generator = FlashcardGenerator(dbQueue: db.dbQueue, resolver: resolver)

        do {
            savedDeck = try generator.saveDeck(perspectivePersonId: person.id, cards: cards)
            showStudyMode = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
