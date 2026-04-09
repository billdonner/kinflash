import XCTest
import GRDB
@testable import KinFlash

final class GEDCOMExporterEdgeCaseTests: XCTestCase {

    private func makeDB() throws -> (DatabaseManager, TreeService) {
        let db = try DatabaseManager(inMemory: true)
        return (db, TreeService(dbQueue: db.dbQueue))
    }

    private func makePerson(firstName: String, lastName: String? = nil, gender: Gender? = nil) -> Person {
        Person(
            id: UUID(), firstName: firstName, middleName: nil, lastName: lastName,
            nickname: nil, birthDate: nil, birthYear: 1970, deathDate: nil, deathYear: nil,
            isLiving: true, birthPlace: nil, gender: gender, notes: nil,
            profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date()
        )
    }

    // MARK: - Fix 4: Single-parent export

    func testExportSingleParentFamily() throws {
        let (db, service) = try makeDB()
        let mom = makePerson(firstName: "Jane", lastName: "Doe", gender: .female)
        let child = makePerson(firstName: "Kid", lastName: "Doe", gender: .male)
        try service.addPerson(mom)
        try service.addPerson(child)
        try service.addRelationship(from: mom.id, to: child.id, type: .parent)

        let exporter = GEDCOMExporter(dbQueue: db.dbQueue)
        let exported = try exporter.export()

        // Child should appear in a FAM record
        XCTAssertTrue(exported.contains("FAM"), "Single-parent family should create a FAM record")
        XCTAssertTrue(exported.contains("CHIL"), "Child should be in the FAM record")
        XCTAssertTrue(exported.contains("WIFE") || exported.contains("HUSB"),
                       "Single parent should appear as HUSB or WIFE in FAM")

        // Re-import and verify no data lost
        let parser = GEDCOMParser()
        let result = parser.parse(content: exported)
        XCTAssertEqual(result.people.count, 2)

        let parentRels = result.relationships.filter { $0.type == .parent }
        XCTAssertGreaterThanOrEqual(parentRels.count, 1, "Parent-child relationship should survive round-trip")
    }

    func testExportParentChildWithoutSpouse() throws {
        let (db, service) = try makeDB()
        let dad = makePerson(firstName: "Dad", lastName: "Smith", gender: .male)
        let mom = makePerson(firstName: "Mom", lastName: "Smith", gender: .female)
        let child = makePerson(firstName: "Child", lastName: "Smith", gender: .male)
        try service.addPerson(dad)
        try service.addPerson(mom)
        try service.addPerson(child)

        // Dad is parent but NOT spouse of Mom
        try service.addRelationship(from: dad.id, to: child.id, type: .parent)
        try service.addRelationship(from: mom.id, to: child.id, type: .parent)

        let exporter = GEDCOMExporter(dbQueue: db.dbQueue)
        let exported = try exporter.export()

        XCTAssertTrue(exported.contains("CHIL"), "Child should appear in exported GEDCOM")

        // Re-import
        let parser = GEDCOMParser()
        let result = parser.parse(content: exported)
        let parentRels = result.relationships.filter { $0.type == .parent }
        XCTAssertGreaterThanOrEqual(parentRels.count, 1, "At least one parent relationship should survive")
    }

    func testExportMultipleSpouseWithChildren() throws {
        let (db, service) = try makeDB()
        let john = makePerson(firstName: "John", gender: .male)
        let wife1 = makePerson(firstName: "Alice", gender: .female)
        let wife2 = makePerson(firstName: "Beth", gender: .female)
        let child1 = makePerson(firstName: "ChildA", gender: .male)
        let child2 = makePerson(firstName: "ChildB", gender: .female)
        try service.addPerson(john)
        try service.addPerson(wife1)
        try service.addPerson(wife2)
        try service.addPerson(child1)
        try service.addPerson(child2)

        try service.addRelationship(from: john.id, to: wife1.id, type: .spouse)
        try service.addRelationship(from: john.id, to: wife2.id, type: .spouse)
        try service.addRelationship(from: john.id, to: child1.id, type: .parent)
        try service.addRelationship(from: wife1.id, to: child1.id, type: .parent)
        try service.addRelationship(from: john.id, to: child2.id, type: .parent)
        try service.addRelationship(from: wife2.id, to: child2.id, type: .parent)

        let exporter = GEDCOMExporter(dbQueue: db.dbQueue)
        let exported = try exporter.export()

        // Should have 2 FAM records
        let famCount = exported.components(separatedBy: "FAM\n").count - 1
        XCTAssertGreaterThanOrEqual(famCount, 2, "Should have at least 2 family groups")
    }
}
