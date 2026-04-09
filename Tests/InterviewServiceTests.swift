import XCTest
import GRDB
@testable import KinFlash

/// Mock AI provider for testing interview extraction and relationship linking.
struct MockAIProvider: AIProvider {
    let responseText: String
    var isAvailable: Bool { true }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Deliver in chunks to verify streaming works
            let words = responseText.components(separatedBy: " ")
            Task {
                for (i, word) in words.enumerated() {
                    continuation.yield(i == 0 ? word : " " + word)
                }
                continuation.finish()
            }
        }
    }
}

final class InterviewServiceTests: XCTestCase {

    private func makeDB() throws -> DatabaseManager {
        try DatabaseManager(inMemory: true)
    }

    // MARK: - Fix 1: Relationship linking

    func testSaveExtractedPersonCreatesRelationships() throws {
        let db = try makeDB()
        let provider = MockAIProvider(responseText: "test")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // First, save the root person (Mary)
        let mary = ExtractedPerson(
            firstName: "Mary", middleName: nil, lastName: "Jones",
            nickname: nil, birthYear: 1948, birthPlace: nil,
            isLiving: true, deathYear: nil, gender: "female",
            relationships: [], isComplete: true
        )
        let savedMary = try service.saveExtractedPerson(mary)

        // Now save John with a spouse relationship to Mary
        let john = ExtractedPerson(
            firstName: "John", middleName: "Robert", lastName: "Smith",
            nickname: nil, birthYear: 1945, birthPlace: "Chicago",
            isLiving: false, deathYear: 2018, gender: "male",
            relationships: [
                ExtractedRelationship(type: "spouse", personName: "Mary Jones")
            ],
            isComplete: true
        )
        let savedJohn = try service.saveExtractedPerson(john)

        // Verify spouse relationship was created (bidirectional = 2 rows)
        let rels = try db.dbQueue.read { database in
            try Relationship.fetchAll(database)
        }
        let spouseRels = rels.filter { $0.type == .spouse }
        XCTAssertEqual(spouseRels.count, 2, "Spouse relationship should create two directed rows")

        // Verify Mary was found by fuzzy match (not duplicated)
        let allPeople = try db.dbQueue.read { database in
            try Person.fetchAll(database)
        }
        let maryCount = allPeople.filter { $0.firstName == "Mary" }.count
        XCTAssertEqual(maryCount, 1, "Mary should not be duplicated")
    }

    func testSaveExtractedPersonCreatesChildRelationship() throws {
        let db = try makeDB()
        let provider = MockAIProvider(responseText: "test")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // Save parent first
        let parent = ExtractedPerson(
            firstName: "Alice", middleName: nil, lastName: "Smith",
            nickname: nil, birthYear: 1960, birthPlace: nil,
            isLiving: true, deathYear: nil, gender: "female",
            relationships: [], isComplete: true
        )
        _ = try service.saveExtractedPerson(parent)

        // Save child with "child" relationship type (I am a child of Alice)
        let child = ExtractedPerson(
            firstName: "Bob", middleName: nil, lastName: "Smith",
            nickname: nil, birthYear: 1990, birthPlace: nil,
            isLiving: true, deathYear: nil, gender: "male",
            relationships: [
                ExtractedRelationship(type: "child", personName: "Alice Smith")
            ],
            isComplete: true
        )
        _ = try service.saveExtractedPerson(child)

        // Verify: Alice should be parent of Bob
        let parentRels = try db.dbQueue.read { database in
            try Relationship.filter(Column("type") == "parent").fetchAll(database)
        }
        XCTAssertEqual(parentRels.count, 1)

        let alice = try db.dbQueue.read { database in
            try Person.filter(Column("firstName") == "Alice").fetchOne(database)
        }!
        let bob = try db.dbQueue.read { database in
            try Person.filter(Column("firstName") == "Bob").fetchOne(database)
        }!

        XCTAssertEqual(parentRels[0].fromPersonId, alice.id, "Alice should be the parent")
        XCTAssertEqual(parentRels[0].toPersonId, bob.id, "Bob should be the child")
    }

    func testSaveExtractedPersonCreatesPlaceholderForUnknownRelative() throws {
        let db = try makeDB()
        let provider = MockAIProvider(responseText: "test")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // Save person with relationship to someone not yet in the database
        let person = ExtractedPerson(
            firstName: "John", middleName: nil, lastName: "Smith",
            nickname: nil, birthYear: 1970, birthPlace: nil,
            isLiving: true, deathYear: nil, gender: "male",
            relationships: [
                ExtractedRelationship(type: "parent", personName: "Michael Smith")
            ],
            isComplete: true
        )
        _ = try service.saveExtractedPerson(person)

        // Michael should have been created as a placeholder
        let allPeople = try db.dbQueue.read { database in
            try Person.fetchAll(database)
        }
        XCTAssertEqual(allPeople.count, 2)
        let michael = allPeople.first { $0.firstName == "Michael" }
        XCTAssertNotNil(michael, "Placeholder person should be created")
        XCTAssertEqual(michael?.lastName, "Smith")
    }

    func testFuzzyMatchUpdatesExistingPerson() throws {
        let db = try makeDB()
        let provider = MockAIProvider(responseText: "test")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // Save person first time without middle name
        let first = ExtractedPerson(
            firstName: "John", middleName: nil, lastName: "Smith",
            nickname: nil, birthYear: 1945, birthPlace: nil,
            isLiving: true, deathYear: nil, gender: "male",
            relationships: [], isComplete: true
        )
        let saved1 = try service.saveExtractedPerson(first)

        // Save again with more detail — should update, not duplicate
        let second = ExtractedPerson(
            firstName: "John", middleName: "Robert", lastName: "Smith",
            nickname: "Johnny", birthYear: 1945, birthPlace: "Chicago",
            isLiving: false, deathYear: 2018, gender: "male",
            relationships: [], isComplete: true
        )
        let saved2 = try service.saveExtractedPerson(second)

        XCTAssertEqual(saved1.id, saved2.id, "Should update the same person, not create a new one")

        let allPeople = try db.dbQueue.read { database in
            try Person.fetchAll(database)
        }
        XCTAssertEqual(allPeople.count, 1)
        XCTAssertEqual(allPeople[0].middleName, "Robert")
        XCTAssertEqual(allPeople[0].birthPlace, "Chicago")
    }

    func testDuplicateRelationshipsIgnored() throws {
        let db = try makeDB()
        let provider = MockAIProvider(responseText: "test")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // Save two people with bidirectional spouse reference
        let person1 = ExtractedPerson(
            firstName: "John", middleName: nil, lastName: "Smith",
            nickname: nil, birthYear: 1945, birthPlace: nil,
            isLiving: true, deathYear: nil, gender: "male",
            relationships: [ExtractedRelationship(type: "spouse", personName: "Mary Jones")],
            isComplete: true
        )
        _ = try service.saveExtractedPerson(person1)

        let person2 = ExtractedPerson(
            firstName: "Mary", middleName: nil, lastName: "Jones",
            nickname: nil, birthYear: 1948, birthPlace: nil,
            isLiving: true, deathYear: nil, gender: "female",
            relationships: [ExtractedRelationship(type: "spouse", personName: "John Smith")],
            isComplete: true
        )
        // This should NOT throw even though the spouse relationship already exists
        _ = try service.saveExtractedPerson(person2)

        let spouseRels = try db.dbQueue.read { database in
            try Relationship.filter(Column("type") == "spouse").fetchAll(database)
        }
        XCTAssertEqual(spouseRels.count, 2, "Should still have exactly 2 spouse rows (one per direction)")
    }
}
