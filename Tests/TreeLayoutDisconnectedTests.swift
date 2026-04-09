import XCTest
import GRDB
@testable import KinFlash

final class TreeLayoutDisconnectedTests: XCTestCase {

    private func makePerson(firstName: String) -> Person {
        Person(
            id: UUID(), firstName: firstName, middleName: nil, lastName: nil,
            nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
            isLiving: true, birthPlace: nil, gender: nil, notes: nil,
            profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date()
        )
    }

    func testDisconnectedSubtreesAreIncluded() throws {
        let db = try DatabaseManager(inMemory: true)
        let now = Date()

        // Component 1: Alice → Bob (parent-child)
        let alice = makePerson(firstName: "Alice")
        let bob = makePerson(firstName: "Bob")

        // Component 2: Carol → Dave (parent-child), completely disconnected
        let carol = makePerson(firstName: "Carol")
        let dave = makePerson(firstName: "Dave")

        try db.dbQueue.write { database in
            try alice.insert(database)
            try bob.insert(database)
            try carol.insert(database)
            try dave.insert(database)

            try Relationship(id: UUID(), fromPersonId: alice.id, toPersonId: bob.id,
                             type: .parent, subtype: nil, startDate: nil, endDate: nil, createdAt: now).insert(database)
            try Relationship(id: UUID(), fromPersonId: carol.id, toPersonId: dave.id,
                             type: .parent, subtype: nil, startDate: nil, endDate: nil, createdAt: now).insert(database)
        }

        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: alice.id)

        // All 4 people should be in the layout, not just Alice + Bob
        XCTAssertEqual(layout.nodes.count, 4, "Disconnected subtree should be included in layout")

        let nodeIds = Set(layout.nodes.map(\.personId))
        XCTAssertTrue(nodeIds.contains(carol.id), "Carol should be in the layout")
        XCTAssertTrue(nodeIds.contains(dave.id), "Dave should be in the layout")
    }

    func testIsolatedPersonIncluded() throws {
        let db = try DatabaseManager(inMemory: true)

        let connected = makePerson(firstName: "Connected")
        let isolated = makePerson(firstName: "Isolated")

        try db.dbQueue.write { database in
            try connected.insert(database)
            try isolated.insert(database)
        }

        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: connected.id)

        XCTAssertEqual(layout.nodes.count, 2, "Isolated person should be included")
    }
}
