import XCTest
import GRDB
@testable import KinFlash

final class DataValidationTests: XCTestCase {

    private func makeDB() throws -> (DatabaseManager, TreeService) {
        let db = try DatabaseManager(inMemory: true)
        let service = TreeService(dbQueue: db.dbQueue)
        return (db, service)
    }

    private func makePerson(firstName: String, lastName: String? = nil) -> Person {
        Person(
            id: UUID(), firstName: firstName, middleName: nil, lastName: lastName,
            nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
            isLiving: true, birthPlace: nil, gender: .male, notes: nil,
            profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date()
        )
    }

    func testSelfRelationshipRejected() throws {
        let (_, service) = try makeDB()
        let person = makePerson(firstName: "Alice")
        try service.addPerson(person)

        XCTAssertThrowsError(
            try service.addRelationship(from: person.id, to: person.id, type: .parent)
        ) { error in
            XCTAssertTrue(error is TreeServiceError)
        }
    }

    func testDuplicateRelationshipRejected() throws {
        let (_, service) = try makeDB()
        let alice = makePerson(firstName: "Alice")
        let bob = makePerson(firstName: "Bob")
        try service.addPerson(alice)
        try service.addPerson(bob)

        try service.addRelationship(from: alice.id, to: bob.id, type: .parent)

        XCTAssertThrowsError(
            try service.addRelationship(from: alice.id, to: bob.id, type: .parent)
        ) { error in
            XCTAssertEqual((error as? TreeServiceError), .duplicateRelationship)
        }
    }

    func testCircularParentChainRejected() throws {
        let (_, service) = try makeDB()
        let alice = makePerson(firstName: "Alice")
        let bob = makePerson(firstName: "Bob")
        let charlie = makePerson(firstName: "Charlie")
        try service.addPerson(alice)
        try service.addPerson(bob)
        try service.addPerson(charlie)

        // Alice is parent of Bob
        try service.addRelationship(from: alice.id, to: bob.id, type: .parent)
        // Bob is parent of Charlie
        try service.addRelationship(from: bob.id, to: charlie.id, type: .parent)

        // Charlie cannot be parent of Alice (would create cycle)
        XCTAssertThrowsError(
            try service.addRelationship(from: charlie.id, to: alice.id, type: .parent)
        ) { error in
            XCTAssertEqual((error as? TreeServiceError), .circularParentChain)
        }
    }

    func testSpouseRelationshipCreatesBothDirections() throws {
        let (db, service) = try makeDB()
        let alice = makePerson(firstName: "Alice")
        let bob = makePerson(firstName: "Bob")
        try service.addPerson(alice)
        try service.addPerson(bob)

        try service.addRelationship(from: alice.id, to: bob.id, type: .spouse)

        let allRels = try db.dbQueue.read { database in
            try Relationship.fetchAll(database)
        }

        let spouseRels = allRels.filter { $0.type == .spouse }
        XCTAssertEqual(spouseRels.count, 2)

        // Should have both directions
        XCTAssertTrue(spouseRels.contains { $0.fromPersonId == alice.id && $0.toPersonId == bob.id })
        XCTAssertTrue(spouseRels.contains { $0.fromPersonId == bob.id && $0.toPersonId == alice.id })
    }

    func testSiblingRelationshipCreatesBothDirections() throws {
        let (db, service) = try makeDB()
        let alice = makePerson(firstName: "Alice")
        let bob = makePerson(firstName: "Bob")
        try service.addPerson(alice)
        try service.addPerson(bob)

        try service.addRelationship(from: alice.id, to: bob.id, type: .sibling)

        let allRels = try db.dbQueue.read { database in
            try Relationship.fetchAll(database)
        }

        let siblingRels = allRels.filter { $0.type == .sibling }
        XCTAssertEqual(siblingRels.count, 2)
    }

    func testCascadeDeletePerson() throws {
        let (db, service) = try makeDB()
        let parent = makePerson(firstName: "Parent")
        let child = makePerson(firstName: "Child")
        try service.addPerson(parent)
        try service.addPerson(child)
        try service.addRelationship(from: parent.id, to: child.id, type: .parent)

        // Delete parent — relationships should cascade
        try service.deletePerson(id: parent.id)

        let remainingRels = try db.dbQueue.read { database in
            try Relationship.fetchAll(database)
        }
        XCTAssertTrue(remainingRels.isEmpty)
    }

    func testInvalidDatesRejected() throws {
        let (_, service) = try makeDB()
        let cal = Calendar.current
        let person = Person(
            id: UUID(), firstName: "Test", middleName: nil, lastName: nil,
            nickname: nil,
            birthDate: cal.date(from: DateComponents(year: 2000, month: 1, day: 1)),
            birthYear: nil,
            deathDate: cal.date(from: DateComponents(year: 1990, month: 1, day: 1)),
            deathYear: nil,
            isLiving: false, birthPlace: nil, gender: nil, notes: nil,
            profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date()
        )

        XCTAssertThrowsError(try service.addPerson(person)) { error in
            XCTAssertEqual((error as? TreeServiceError), .invalidDates)
        }
    }

    func testPersonNotFoundRejected() throws {
        let (_, service) = try makeDB()
        let alice = makePerson(firstName: "Alice")
        try service.addPerson(alice)

        XCTAssertThrowsError(
            try service.addRelationship(from: alice.id, to: UUID(), type: .parent)
        ) { error in
            XCTAssertEqual((error as? TreeServiceError), .personNotFound)
        }
    }
}

extension TreeServiceError: Equatable {
    public static func == (lhs: TreeServiceError, rhs: TreeServiceError) -> Bool {
        switch (lhs, rhs) {
        case (.selfRelationship, .selfRelationship),
             (.duplicateRelationship, .duplicateRelationship),
             (.circularParentChain, .circularParentChain),
             (.personNotFound, .personNotFound),
             (.invalidDates, .invalidDates):
            return true
        default:
            return false
        }
    }
}
