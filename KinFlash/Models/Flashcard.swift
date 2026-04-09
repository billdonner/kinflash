import Foundation
import GRDB

enum FlashcardStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case unknown
    case learning
    case known
}

struct FlashcardDeck: Codable, Sendable, Identifiable {
    var id: UUID
    var perspectivePersonId: UUID
    var generatedAt: Date
    var cardCount: Int
}

extension FlashcardDeck: FetchableRecord, PersistableRecord {
    static let databaseTableName = "flashcardDeck"
}

struct Flashcard: Codable, Sendable, Identifiable {
    var id: UUID
    var deckId: UUID
    var question: String
    var answer: String
    var explanation: String?
    var chain: String?
    var status: FlashcardStatus
    var lastReviewedAt: Date?
}

extension Flashcard: FetchableRecord, PersistableRecord {
    static let databaseTableName = "flashcard"
}
