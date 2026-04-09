import XCTest
import GRDB
@testable import KinFlash

final class FlashcardGeneratorTests: XCTestCase {

    private func setupSampleTree() throws -> (DatabaseManager, [String: Person]) {
        let db = try DatabaseManager(inMemory: true)
        let parser = GEDCOMParser()

        let gedcom = """
        0 HEAD
        1 SOUR KinFlash
        1 GEDC
        2 VERS 5.5.1
        0 @I1@ INDI
        1 NAME Robert /Smith/
        1 SEX M
        1 BIRT
        2 DATE 15 FEB 1920
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME Helen /Brown/
        1 SEX F
        1 BIRT
        2 DATE 22 AUG 1922
        1 FAMS @F1@
        0 @I3@ INDI
        1 NAME John /Smith/
        1 SEX M
        1 BIRT
        2 DATE 12 JUN 1945
        1 FAMC @F1@
        1 FAMS @F2@
        0 @I4@ INDI
        1 NAME Carol /Smith/
        1 SEX F
        1 BIRT
        2 DATE 7 OCT 1948
        1 FAMC @F1@
        0 @I5@ INDI
        1 NAME Mary /Jones/
        1 SEX F
        1 BIRT
        2 DATE 3 MAR 1948
        1 FAMS @F2@
        0 @I6@ INDI
        1 NAME Michael /Smith/
        1 SEX M
        1 BIRT
        2 DATE 15 SEP 1970
        1 FAMC @F2@
        0 @F1@ FAM
        1 HUSB @I1@
        1 WIFE @I2@
        1 CHIL @I3@
        1 CHIL @I4@
        0 @F2@ FAM
        1 HUSB @I3@
        1 WIFE @I5@
        1 CHIL @I6@
        0 TRLR
        """

        let result = parser.parse(content: gedcom)
        try parser.importToDatabase(result, dbQueue: db.dbQueue)

        let people = try db.dbQueue.read { database in
            try Person.fetchAll(database)
        }
        let personMap = Dictionary(uniqueKeysWithValues: people.map { ($0.firstName, $0) })

        return (db, personMap)
    }

    func testGeneratesCardsForMichael() throws {
        let (db, people) = try setupSampleTree()
        let michael = people["Michael"]!

        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let generator = FlashcardGenerator(dbQueue: db.dbQueue, resolver: resolver)

        let cards = try generator.generate(perspectivePersonId: michael.id)

        // Michael should have cards for: John (Father), Mary (Mother),
        // Robert (Grandfather), Helen (Grandmother), Carol (Aunt)
        // At minimum 5 cards
        XCTAssertGreaterThanOrEqual(cards.count, 5)

        // Verify a specific card
        let fatherCard = cards.first { $0.answer.contains("John") }
        XCTAssertNotNil(fatherCard)
        XCTAssertTrue(fatherCard!.question.contains("parent"))
    }

    func testSavesDeckToDatabase() throws {
        let (db, people) = try setupSampleTree()
        let michael = people["Michael"]!

        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let generator = FlashcardGenerator(dbQueue: db.dbQueue, resolver: resolver)

        let cards = try generator.generate(perspectivePersonId: michael.id)
        let deck = try generator.saveDeck(perspectivePersonId: michael.id, cards: cards)

        XCTAssertEqual(deck.cardCount, cards.count)
        XCTAssertEqual(deck.perspectivePersonId, michael.id)

        // Verify cards are in the database
        let savedCards = try db.dbQueue.read { database in
            try Flashcard.filter(Column("deckId") == deck.id).fetchAll(database)
        }
        XCTAssertEqual(savedCards.count, cards.count)
        XCTAssertTrue(savedCards.allSatisfy { $0.status == .unknown })
    }

    func testCardsAreSortedByHopCount() throws {
        let (db, people) = try setupSampleTree()
        let michael = people["Michael"]!

        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let generator = FlashcardGenerator(dbQueue: db.dbQueue, resolver: resolver)

        let cards = try generator.generate(perspectivePersonId: michael.id)

        // First cards should be shorter chains (1-hop), later should be longer
        if cards.count >= 2 {
            let firstChainLength = cards.first!.relationshipChain.components(separatedBy: " → ").count
            let lastChainLength = cards.last!.relationshipChain.components(separatedBy: " → ").count
            XCTAssertLessThanOrEqual(firstChainLength, lastChainLength)
        }
    }
}
