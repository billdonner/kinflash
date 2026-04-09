import Foundation
import GRDB

struct FlashcardGenerator: Sendable {
    let dbQueue: DatabaseQueue
    let resolver: RelationshipResolver

    /// Generate flashcards for a given perspective person (no AI needed for basic generation).
    func generate(perspectivePersonId: UUID) throws -> [GeneratedFlashcard] {
        let labels = try resolver.resolveAll(from: perspectivePersonId)

        let people = try dbQueue.read { db in
            try Person.fetchAll(db)
        }
        let personMap = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })

        var cards: [GeneratedFlashcard] = []

        for (targetId, label) in labels {
            guard let target = personMap[targetId] else { continue }

            let question = buildQuestion(chain: label.chain, label: label.label)
            let answer = target.displayName

            let explanation = buildExplanation(target: target, label: label.label)

            cards.append(GeneratedFlashcard(
                question: question,
                answer: "\(answer) (your \(label.label))",
                explanation: explanation,
                relationshipChain: label.chainDescription
            ))
        }

        return cards.sorted {
            // Sort by number of traversal edges (hops), not string length
            let hops0 = $0.relationshipChain.components(separatedBy: " \u{2192} ").count  // "→" separator
            let hops1 = $1.relationshipChain.components(separatedBy: " \u{2192} ").count
            return hops0 < hops1
        }
    }

    /// Save generated flashcards as a deck in the database.
    func saveDeck(perspectivePersonId: UUID, cards: [GeneratedFlashcard]) throws -> FlashcardDeck {
        let deck = FlashcardDeck(
            id: UUID(),
            perspectivePersonId: perspectivePersonId,
            generatedAt: Date(),
            cardCount: cards.count
        )

        try dbQueue.write { db in
            try deck.insert(db)
            for card in cards {
                let flashcard = Flashcard(
                    id: UUID(),
                    deckId: deck.id,
                    question: card.question,
                    answer: card.answer,
                    explanation: card.explanation,
                    chain: card.relationshipChain,
                    status: .unknown,
                    lastReviewedAt: nil
                )
                try flashcard.insert(db)
            }
        }

        return deck
    }

    // MARK: - Question Building

    private func buildQuestion(chain: [TraversalEdge], label: String) -> String {
        switch chain.count {
        case 1:
            return "Who is your \(edgeLabel(chain[0]))?"
        case 2:
            return "Who is your \(edgeLabel(chain[0]))'s \(edgeLabel(chain[1]))?"
        case 3:
            return "Who is your \(edgeLabel(chain[0]))'s \(edgeLabel(chain[1]))'s \(edgeLabel(chain[2]))?"
        case 4:
            return "Who is your \(edgeLabel(chain[0]))'s \(edgeLabel(chain[1]))'s \(edgeLabel(chain[2]))'s \(edgeLabel(chain[3]))?"
        default:
            return "Who is your \(label.lowercased())?"
        }
    }

    private func edgeLabel(_ edge: TraversalEdge) -> String {
        switch edge {
        case .parent: return "parent"
        case .child: return "child"
        case .spouse: return "spouse"
        case .sibling: return "sibling"
        }
    }

    private func buildExplanation(target: Person, label: String) -> String? {
        var parts: [String] = []
        parts.append("\(target.displayName) is your \(label.lowercased()).")

        if let years = target.displayYears {
            parts.append("(\(years))")
        }

        if let notes = target.notes, !notes.isEmpty {
            parts.append(notes)
        }

        return parts.count > 1 ? parts.joined(separator: " ") : nil
    }
}

struct GeneratedFlashcard: Codable, Sendable {
    let question: String
    let answer: String
    let explanation: String?
    let relationshipChain: String
}
