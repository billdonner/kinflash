import XCTest
import GRDB
@testable import KinFlash

final class BidirectionalDeleteTests: XCTestCase {

    private func makeDB() throws -> (DatabaseManager, TreeService) {
        let db = try DatabaseManager(inMemory: true)
        return (db, TreeService(dbQueue: db.dbQueue))
    }

    private func makePerson(firstName: String, gender: Gender = .unknown) -> Person {
        Person(
            id: UUID(), firstName: firstName, middleName: nil, lastName: nil,
            nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
            isLiving: true, birthPlace: nil, gender: gender, notes: nil,
            profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date()
        )
    }

    // MARK: - Fix 3: Bidirectional delete

    func testDeleteSpouseRemovesBothDirections() throws {
        let (db, service) = try makeDB()
        let alice = makePerson(firstName: "Alice", gender: .female)
        let bob = makePerson(firstName: "Bob", gender: .male)
        try service.addPerson(alice)
        try service.addPerson(bob)
        try service.addRelationship(from: alice.id, to: bob.id, type: .spouse)

        // Should have 2 spouse rows
        var rels = try db.dbQueue.read { database in try Relationship.fetchAll(database) }
        XCTAssertEqual(rels.filter { $0.type == .spouse }.count, 2)

        // Delete one spouse relationship by id
        let oneSpouseRel = rels.first { $0.type == .spouse }!
        try service.removeRelationship(id: oneSpouseRel.id)

        // Both directions should be gone
        rels = try db.dbQueue.read { database in try Relationship.fetchAll(database) }
        XCTAssertEqual(rels.filter { $0.type == .spouse }.count, 0, "Both spouse rows should be deleted")
    }

    func testDeleteSiblingRemovesBothDirections() throws {
        let (db, service) = try makeDB()
        let alice = makePerson(firstName: "Alice")
        let bob = makePerson(firstName: "Bob")
        try service.addPerson(alice)
        try service.addPerson(bob)
        try service.addRelationship(from: alice.id, to: bob.id, type: .sibling)

        var rels = try db.dbQueue.read { database in try Relationship.fetchAll(database) }
        XCTAssertEqual(rels.filter { $0.type == .sibling }.count, 2)

        let oneSiblingRel = rels.first { $0.type == .sibling }!
        try service.removeRelationship(id: oneSiblingRel.id)

        rels = try db.dbQueue.read { database in try Relationship.fetchAll(database) }
        XCTAssertEqual(rels.filter { $0.type == .sibling }.count, 0, "Both sibling rows should be deleted")
    }

    func testDeleteParentOnlyRemovesOneRow() throws {
        let (db, service) = try makeDB()
        let parent = makePerson(firstName: "Parent")
        let child = makePerson(firstName: "Child")
        try service.addPerson(parent)
        try service.addPerson(child)
        try service.addRelationship(from: parent.id, to: child.id, type: .parent)

        var rels = try db.dbQueue.read { database in try Relationship.fetchAll(database) }
        XCTAssertEqual(rels.count, 1)

        try service.removeRelationship(id: rels[0].id)

        rels = try db.dbQueue.read { database in try Relationship.fetchAll(database) }
        XCTAssertEqual(rels.count, 0)
    }
}
