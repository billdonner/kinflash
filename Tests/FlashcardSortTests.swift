import XCTest
import GRDB
@testable import KinFlash

final class FlashcardSortTests: XCTestCase {

    func testCardsSortedByEdgeCountNotStringLength() throws {
        let db = try DatabaseManager(inMemory: true)
        let now = Date()

        // Create a 3-generation tree: grandparent → parent → child
        let grandpa = Person(id: UUID(), firstName: "Grandpa", middleName: nil, lastName: nil,
                             nickname: nil, birthDate: nil, birthYear: 1940, deathDate: nil, deathYear: nil,
                             isLiving: false, birthPlace: nil, gender: .male, notes: nil,
                             profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now)
        let dad = Person(id: UUID(), firstName: "Dad", middleName: nil, lastName: nil,
                         nickname: nil, birthDate: nil, birthYear: 1965, deathDate: nil, deathYear: nil,
                         isLiving: true, birthPlace: nil, gender: .male, notes: nil,
                         profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now)
        let child = Person(id: UUID(), firstName: "Child", middleName: nil, lastName: nil,
                           nickname: nil, birthDate: nil, birthYear: 1990, deathDate: nil, deathYear: nil,
                           isLiving: true, birthPlace: nil, gender: .male, notes: nil,
                           profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now)

        try db.dbQueue.write { database in
            try grandpa.insert(database)
            try dad.insert(database)
            try child.insert(database)
            // grandpa is parent of dad
            try Relationship(id: UUID(), fromPersonId: grandpa.id, toPersonId: dad.id,
                             type: .parent, subtype: nil, startDate: nil, endDate: nil, createdAt: now).insert(database)
            // dad is parent of child
            try Relationship(id: UUID(), fromPersonId: dad.id, toPersonId: child.id,
                             type: .parent, subtype: nil, startDate: nil, endDate: nil, createdAt: now).insert(database)
        }

        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let generator = FlashcardGenerator(dbQueue: db.dbQueue, resolver: resolver)
        let cards = try generator.generate(perspectivePersonId: child.id)

        XCTAssertEqual(cards.count, 2) // Dad (1 hop) and Grandpa (2 hops)

        // First card should be 1-hop (parent), second should be 2-hop (grandparent)
        let firstHops = cards[0].relationshipChain.components(separatedBy: " \u{2192} ").count
        let secondHops = cards[1].relationshipChain.components(separatedBy: " \u{2192} ").count
        XCTAssertLessThanOrEqual(firstHops, secondHops, "Cards should be sorted by hop count")
        XCTAssertEqual(firstHops, 1)
        XCTAssertEqual(secondHops, 2)
    }
}
