import XCTest
import GRDB
@testable import KinFlash

final class RelationshipResolverTests: XCTestCase {

    /// Helper: create an in-memory database and populate from the sample GEDCOM.
    /// Returns (db, resolver, personMap keyed by firstName)
    private func setupSampleTree() throws -> (DatabaseManager, RelationshipResolver, [String: Person]) {
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
        1 DEAT
        2 DATE 8 NOV 1990
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME Helen /Brown/
        1 SEX F
        1 BIRT
        2 DATE 22 AUG 1922
        1 DEAT
        2 DATE 1 MAR 2005
        1 FAMS @F1@
        0 @I3@ INDI
        1 NAME John /Smith/
        1 SEX M
        1 BIRT
        2 DATE 12 JUN 1945
        1 DEAT
        2 DATE 3 MAR 2018
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
        0 @I7@ INDI
        1 NAME David /Smith/
        1 SEX M
        1 BIRT
        2 DATE 4 JAN 1973
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
        1 CHIL @I7@
        0 TRLR
        """

        let result = parser.parse(content: gedcom)
        try parser.importToDatabase(result, dbQueue: db.dbQueue)

        let people = try db.dbQueue.read { database in
            try Person.fetchAll(database)
        }
        let personMap = Dictionary(uniqueKeysWithValues: people.map { ($0.firstName, $0) })

        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        return (db, resolver, personMap)
    }

    // MARK: - 1-hop tests

    func testParentRelationship() throws {
        let (_, resolver, people) = try setupSampleTree()
        let michael = people["Michael"]!
        let john = people["John"]!

        // Michael's parent is John
        let label = try resolver.resolve(from: michael.id, to: john.id)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.label, "Father")
    }

    func testChildRelationship() throws {
        let (_, resolver, people) = try setupSampleTree()
        let john = people["John"]!
        let michael = people["Michael"]!

        // John's child is Michael
        let label = try resolver.resolve(from: john.id, to: michael.id)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.label, "Son")
    }

    func testSpouseRelationship() throws {
        let (_, resolver, people) = try setupSampleTree()
        let john = people["John"]!
        let mary = people["Mary"]!

        let label = try resolver.resolve(from: john.id, to: mary.id)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.label, "Wife")
    }

    func testSiblingRelationship() throws {
        let (_, resolver, people) = try setupSampleTree()
        let john = people["John"]!
        let carol = people["Carol"]!

        let label = try resolver.resolve(from: john.id, to: carol.id)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.label, "Sister")
    }

    // MARK: - 2-hop tests

    func testGrandparentRelationship() throws {
        let (_, resolver, people) = try setupSampleTree()
        let michael = people["Michael"]!
        let robert = people["Robert"]!

        let label = try resolver.resolve(from: michael.id, to: robert.id)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.label, "Grandfather")
    }

    func testGrandchildRelationship() throws {
        let (_, resolver, people) = try setupSampleTree()
        let robert = people["Robert"]!
        let michael = people["Michael"]!

        let label = try resolver.resolve(from: robert.id, to: michael.id)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.label, "Grandson")
    }

    func testUncleAuntRelationship() throws {
        let (_, resolver, people) = try setupSampleTree()
        let michael = people["Michael"]!
        let carol = people["Carol"]!

        // Michael's father's sister = Carol = Aunt
        let label = try resolver.resolve(from: michael.id, to: carol.id)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.label, "Aunt")
    }

    func testNephewNieceRelationship() throws {
        let (_, resolver, people) = try setupSampleTree()
        let carol = people["Carol"]!
        let michael = people["Michael"]!

        // Carol's brother's son = Michael = Nephew
        let label = try resolver.resolve(from: carol.id, to: michael.id)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.label, "Nephew")
    }

    func testMotherInLaw() throws {
        let (_, resolver, people) = try setupSampleTree()
        let mary = people["Mary"]!
        let helen = people["Helen"]!

        // Mary's spouse's mother = Helen = Mother-in-law
        let label = try resolver.resolve(from: mary.id, to: helen.id)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.label, "Mother-in-law")
    }

    // MARK: - 3-hop tests

    func testGreatGrandparentRelationship() throws {
        // We don't have 4 generations in the test data, but we can verify the path logic
        // Robert → John → Michael: Robert is grandfather of Michael
        // This is already tested. For 3-hop we test uncle/aunt from grandchild perspective.
        let (_, resolver, people) = try setupSampleTree()
        let david = people["David"]!
        let carol = people["Carol"]!

        // David's father's sister = Carol = Aunt
        let label = try resolver.resolve(from: david.id, to: carol.id)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.label, "Aunt")
    }

    // MARK: - resolveAll

    func testResolveAllFromMichael() throws {
        let (_, resolver, people) = try setupSampleTree()
        let michael = people["Michael"]!

        let all = try resolver.resolveAll(from: michael.id)

        // Michael should see: John (Father), Mary (Mother), David (Brother),
        // Robert (Grandfather), Helen (Grandmother), Carol (Aunt)
        XCTAssertGreaterThanOrEqual(all.count, 6)

        let john = people["John"]!
        XCTAssertEqual(all[john.id]?.label, "Father")

        let mary = people["Mary"]!
        XCTAssertEqual(all[mary.id]?.label, "Mother")

        let david = people["David"]!
        XCTAssertEqual(all[david.id]?.label, "Brother")
    }

    // MARK: - Self relationship

    func testSelfReturnsNil() throws {
        let (_, resolver, people) = try setupSampleTree()
        let michael = people["Michael"]!
        let label = try resolver.resolve(from: michael.id, to: michael.id)
        XCTAssertNil(label)
    }

    // MARK: - Gender-neutral

    func testGenderNeutralLabels() throws {
        let db = try DatabaseManager(inMemory: true)
        let now = Date()

        let parent = Person(
            id: UUID(), firstName: "Pat", middleName: nil, lastName: "Smith",
            nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
            isLiving: true, birthPlace: nil, gender: .nonBinary, notes: nil,
            profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now
        )
        let child = Person(
            id: UUID(), firstName: "Chris", middleName: nil, lastName: "Smith",
            nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
            isLiving: true, birthPlace: nil, gender: .unknown, notes: nil,
            profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now
        )

        try db.dbQueue.write { database in
            try parent.insert(database)
            try child.insert(database)
            let rel = Relationship(
                id: UUID(), fromPersonId: parent.id, toPersonId: child.id,
                type: .parent, subtype: nil, startDate: nil, endDate: nil, createdAt: now
            )
            try rel.insert(database)
        }

        let resolver = RelationshipResolver(dbQueue: db.dbQueue)

        // From child's perspective, parent should be "Parent" (not Father/Mother)
        let label = try resolver.resolve(from: child.id, to: parent.id)
        XCTAssertEqual(label?.label, "Parent")

        // From parent's perspective, child should be "Child" (not Son/Daughter)
        let childLabel = try resolver.resolve(from: parent.id, to: child.id)
        XCTAssertEqual(childLabel?.label, "Child")
    }
}
