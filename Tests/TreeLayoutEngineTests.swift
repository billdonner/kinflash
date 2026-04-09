import XCTest
import GRDB
@testable import KinFlash

final class TreeLayoutEngineTests: XCTestCase {

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
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME Helen /Brown/
        1 SEX F
        1 FAMS @F1@
        0 @I3@ INDI
        1 NAME John /Smith/
        1 SEX M
        1 FAMC @F1@
        1 FAMS @F2@
        0 @I4@ INDI
        1 NAME Carol /Smith/
        1 SEX F
        1 FAMC @F1@
        0 @I5@ INDI
        1 NAME Mary /Jones/
        1 SEX F
        1 FAMS @F2@
        0 @I6@ INDI
        1 NAME Michael /Smith/
        1 SEX M
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

    func testLayoutAssignsGenerations() throws {
        let (db, people) = try setupSampleTree()
        let michael = people["Michael"]!

        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: michael.id)

        // Should have all 6 connected people
        XCTAssertEqual(layout.nodes.count, 6)

        // Find generation assignments
        let nodeMap = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.personId, $0) })

        let michaelNode = nodeMap[michael.id]!
        let johnNode = nodeMap[people["John"]!.id]!
        let maryNode = nodeMap[people["Mary"]!.id]!
        let robertNode = nodeMap[people["Robert"]!.id]!

        // Michael is root (gen 0), parents are gen -1, grandparents are gen -2
        XCTAssertEqual(michaelNode.generation, 0)
        XCTAssertEqual(johnNode.generation, -1)
        XCTAssertEqual(maryNode.generation, -1)
        XCTAssertEqual(robertNode.generation, -2)
    }

    func testSpousesOnSameGeneration() throws {
        let (db, people) = try setupSampleTree()
        let michael = people["Michael"]!

        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: michael.id)

        let nodeMap = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.personId, $0) })

        let johnNode = nodeMap[people["John"]!.id]!
        let maryNode = nodeMap[people["Mary"]!.id]!

        XCTAssertEqual(johnNode.generation, maryNode.generation)
    }

    func testLayoutHasPositiveSize() throws {
        let (db, people) = try setupSampleTree()
        let michael = people["Michael"]!

        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: michael.id)

        XCTAssertGreaterThan(layout.totalSize.width, 0)
        XCTAssertGreaterThan(layout.totalSize.height, 0)
    }

    func testLayoutHasConnections() throws {
        let (db, people) = try setupSampleTree()
        let michael = people["Michael"]!

        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: michael.id)

        XCTAssertGreaterThan(layout.connections.count, 0)
    }

    func testSinglePersonLayout() throws {
        let db = try DatabaseManager(inMemory: true)
        let now = Date()
        let person = Person(
            id: UUID(), firstName: "Solo", middleName: nil, lastName: nil,
            nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
            isLiving: true, birthPlace: nil, gender: nil, notes: nil,
            profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now
        )

        try db.dbQueue.write { database in
            try person.insert(database)
        }

        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: person.id)

        XCTAssertEqual(layout.nodes.count, 1)
        XCTAssertEqual(layout.connections.count, 0)
    }
}
