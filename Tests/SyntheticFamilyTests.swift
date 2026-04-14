import XCTest
import GRDB
@testable import KinFlash

/// Tests a large synthetic family: 4 grandparents, 5 children, 4 spouses-in-law, 13 grandchildren = 25 people
///
/// Family structure:
///   Robert Smith + Helen Brown (paternal grandparents)
///     ├── John Smith + Mary Jones → Michael, Sarah, Emily, Daniel Smith
///     ├── Carol Smith + Frank Wilson → Jessica, Ryan, Nicole Wilson
///     └── David Smith + Lisa Brown → Kevin, Amanda, Tyler Smith
///
///   William Jones + Margaret O'Brien (maternal grandparents)
///     ├── Mary Jones (married John Smith above)
///     └── Thomas Jones + Patricia Davis → Christopher, Jennifer, Matthew Jones
///
final class SyntheticFamilyTests: XCTestCase {

    private func loadSampleFamily() throws -> (DatabaseManager, [Person]) {
        let db = try DatabaseManager(inMemory: true)

        // Load the GEDCOM file — try bundle first, then source tree paths
        let gedcomContent: String
        if let url = Bundle(for: type(of: self)).url(forResource: "SampleFamily", withExtension: "ged") {
            gedcomContent = try String(contentsOf: url)
        } else {
            // Source tree fallback — #file gives the test file's path
            let sourceRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests/
                .deletingLastPathComponent()  // kinflash/
            let filePath = sourceRoot.appendingPathComponent("KinFlash/Resources/SampleFamily.ged")
            gedcomContent = try String(contentsOf: filePath)
        }

        let parser = GEDCOMParser()
        let result = parser.parse(content: gedcomContent)
        try parser.importToDatabase(result, dbQueue: db.dbQueue)

        let people = try db.dbQueue.read { database in
            try Person.fetchAll(database)
        }

        return (db, people)
    }

    // MARK: - Import Counts

    func testImports25People() throws {
        let (_, people) = try loadSampleFamily()
        XCTAssertEqual(people.count, 25, "Should import all 25 family members")
    }

    func testImportsCorrectRelationshipCount() throws {
        let (db, _) = try loadSampleFamily()
        let rels = try db.dbQueue.read { database in
            try Relationship.fetchAll(database)
        }
        // 6 spouse pairs (12 rows) + 13 parent-child (26 rows) + sibling pairs
        let spouseCount = rels.filter { $0.type == .spouse }.count
        let parentCount = rels.filter { $0.type == .parent }.count
        let siblingCount = rels.filter { $0.type == .sibling }.count

        print("[SyntheticFamily] Relationships: \(spouseCount) spouse, \(parentCount) parent, \(siblingCount) sibling")
        XCTAssertEqual(spouseCount, 12, "6 couples × 2 directions = 12 spouse rows")
        XCTAssertGreaterThanOrEqual(parentCount, 26, "At least 13 children × 2 parents = 26 parent rows")
        XCTAssertGreaterThan(siblingCount, 0, "Should have sibling relationships")
    }

    // MARK: - Grandparent Verification

    func testPaternalGrandparents() throws {
        let (_, people) = try loadSampleFamily()
        let robert = people.first { $0.firstName == "Robert" && $0.lastName == "Smith" }
        let helen = people.first { $0.firstName == "Helen" && $0.lastName == "Brown" }
        XCTAssertNotNil(robert)
        XCTAssertNotNil(helen)
        XCTAssertEqual(robert?.gender, .male)
        XCTAssertEqual(helen?.gender, .female)
        XCTAssertFalse(robert!.isLiving, "Robert died in 2010")
    }

    func testMaternalGrandparents() throws {
        let (_, people) = try loadSampleFamily()
        let william = people.first { $0.firstName == "William" && $0.lastName == "Jones" }
        let margaret = people.first { $0.firstName == "Margaret" }
        XCTAssertNotNil(william)
        XCTAssertNotNil(margaret)
        XCTAssertFalse(william!.isLiving, "William died in 2015")
    }

    // MARK: - Children Generation

    func testSmithChildren() throws {
        let (db, people) = try loadSampleFamily()
        let robert = people.first { $0.firstName == "Robert" && $0.lastName == "Smith" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let labels = try resolver.resolveAll(from: robert.id)

        let children = labels.filter { $0.value.label == "Son" || $0.value.label == "Daughter" }
        XCTAssertEqual(children.count, 3, "Robert should have 3 children: John, Carol, David")
    }

    func testJonesChildren() throws {
        let (db, people) = try loadSampleFamily()
        let william = people.first { $0.firstName == "William" && $0.lastName == "Jones" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let labels = try resolver.resolveAll(from: william.id)

        let children = labels.filter { $0.value.label == "Son" || $0.value.label == "Daughter" }
        XCTAssertEqual(children.count, 2, "William should have 2 children: Mary, Thomas")
    }

    // MARK: - Grandchildren

    func testJohnAndMaryHave4Children() throws {
        let (db, people) = try loadSampleFamily()
        let john = people.first { $0.firstName == "John" && $0.lastName == "Smith" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let labels = try resolver.resolveAll(from: john.id)

        let children = labels.filter { $0.value.label == "Son" || $0.value.label == "Daughter" }
        XCTAssertEqual(children.count, 4, "John+Mary should have 4 children")

        let childNames = children.compactMap { entry in people.first(where: { p in p.id == entry.key })?.firstName }
        print("[SyntheticFamily] John's children: \(childNames)")
        XCTAssertTrue(childNames.contains("Michael"))
        XCTAssertTrue(childNames.contains("Sarah"))
        XCTAssertTrue(childNames.contains("Emily"))
        XCTAssertTrue(childNames.contains("Daniel"))
    }

    func testCarolAndFrankHave3Children() throws {
        let (db, people) = try loadSampleFamily()
        let carol = people.first { $0.firstName == "Carol" && $0.lastName == "Smith" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let labels = try resolver.resolveAll(from: carol.id)

        let children = labels.filter { $0.value.label == "Son" || $0.value.label == "Daughter" }
        XCTAssertEqual(children.count, 3, "Carol+Frank should have 3 children")
    }

    func testDavidAndLisaHave3Children() throws {
        let (db, people) = try loadSampleFamily()
        let david = people.first { $0.firstName == "David" && $0.lastName == "Smith" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let labels = try resolver.resolveAll(from: david.id)

        let children = labels.filter { $0.value.label == "Son" || $0.value.label == "Daughter" }
        XCTAssertEqual(children.count, 3, "David+Lisa should have 3 children")
    }

    func testThomasAndPatriciaHave3Children() throws {
        let (db, people) = try loadSampleFamily()
        let thomas = people.first { $0.firstName == "Thomas" && $0.lastName == "Jones" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let labels = try resolver.resolveAll(from: thomas.id)

        let children = labels.filter { $0.value.label == "Son" || $0.value.label == "Daughter" }
        XCTAssertEqual(children.count, 3, "Thomas+Patricia should have 3 children")
    }

    // MARK: - Cross-Family Relationships

    func testMichaelGrandparents() throws {
        let (db, people) = try loadSampleFamily()
        let michael = people.first { $0.firstName == "Michael" && $0.lastName == "Smith" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let labels = try resolver.resolveAll(from: michael.id)

        let grandparents = labels.filter {
            $0.value.label == "Grandfather" || $0.value.label == "Grandmother"
        }
        XCTAssertEqual(grandparents.count, 4, "Michael should have 4 grandparents (Robert, Helen, William, Margaret)")
    }

    func testMichaelUnclesAndAunts() throws {
        let (db, people) = try loadSampleFamily()
        let michael = people.first { $0.firstName == "Michael" && $0.lastName == "Smith" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let labels = try resolver.resolveAll(from: michael.id)

        let unclesAunts = labels.filter {
            $0.value.label == "Uncle" || $0.value.label == "Aunt"
        }
        // Carol (aunt), David (uncle), Thomas (uncle)
        print("[SyntheticFamily] Michael's uncles/aunts: \(unclesAunts.map { $0.value.label })")
        XCTAssertGreaterThanOrEqual(unclesAunts.count, 3, "Michael should have at least 3 uncles/aunts")
    }

    func testCousins() throws {
        let (db, people) = try loadSampleFamily()
        let michael = people.first { $0.firstName == "Michael" && $0.lastName == "Smith" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let labels = try resolver.resolveAll(from: michael.id)

        let cousins = labels.filter { $0.value.label == "First Cousin" }
        // Jessica, Ryan, Nicole (Wilson) + Kevin, Amanda, Tyler (Smith) + Christopher, Jennifer, Matthew (Jones)
        print("[SyntheticFamily] Michael's cousins: \(cousins.count)")
        XCTAssertGreaterThanOrEqual(cousins.count, 6, "Michael should have at least 6 first cousins")
    }

    func testSpouseRelationship() throws {
        let (db, people) = try loadSampleFamily()
        let john = people.first { $0.firstName == "John" && $0.lastName == "Smith" }!
        let mary = people.first { $0.firstName == "Mary" && $0.lastName == "Jones" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)

        let label = try resolver.resolve(from: john.id, to: mary.id)
        XCTAssertEqual(label?.label, "Wife", "Mary should be John's wife")
    }

    func testMotherInLaw() throws {
        let (db, people) = try loadSampleFamily()
        let john = people.first { $0.firstName == "John" && $0.lastName == "Smith" }!
        let margaret = people.first { $0.firstName == "Margaret" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)

        let label = try resolver.resolve(from: john.id, to: margaret.id)
        XCTAssertEqual(label?.label, "Mother-in-law", "Margaret should be John's mother-in-law")
    }

    // MARK: - Tree Layout

    func testLayoutIncludes25Nodes() throws {
        let (db, people) = try loadSampleFamily()
        let john = people.first { $0.firstName == "John" && $0.lastName == "Smith" }!
        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: john.id)

        XCTAssertEqual(layout.nodes.count, 25, "Layout should include all 25 people")
        XCTAssertGreaterThan(layout.connections.count, 0, "Should have connection lines")
        print("[SyntheticFamily] Layout: \(layout.nodes.count) nodes, \(layout.connections.count) connections, size: \(layout.totalSize)")
    }

    func testLayoutHas4Generations() throws {
        let (db, people) = try loadSampleFamily()
        let michael = people.first { $0.firstName == "Michael" && $0.lastName == "Smith" }!
        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: michael.id)

        let generations = Set(layout.nodes.map(\.generation))
        print("[SyntheticFamily] Generations from Michael's perspective: \(generations.sorted())")
        // Michael (0), parents (-1), grandparents (-2), siblings (0), cousins (0)
        XCTAssertGreaterThanOrEqual(generations.count, 3, "Should span at least 3 generation levels")
    }

    // MARK: - Flashcard Generation

    func testFlashcardsFromMichael() throws {
        let (db, people) = try loadSampleFamily()
        let michael = people.first { $0.firstName == "Michael" && $0.lastName == "Smith" }!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let generator = FlashcardGenerator(dbQueue: db.dbQueue, resolver: resolver)

        let cards = try generator.generate(perspectivePersonId: michael.id)
        print("[SyntheticFamily] Flashcards for Michael: \(cards.count) cards")
        for card in cards.prefix(5) {
            print("  Q: \(card.question) → A: \(card.answer)")
        }

        // Michael should have cards for: parents (2), grandparents (4), siblings (3),
        // spouse of parents (0 extra), uncle/aunt (3+), cousins (6+)
        XCTAssertGreaterThanOrEqual(cards.count, 10, "Should generate at least 10 flashcards")
    }

    // MARK: - GEDCOM Round-Trip

    func testGEDCOMRoundTrip() throws {
        let (db, people) = try loadSampleFamily()
        let exporter = GEDCOMExporter(dbQueue: db.dbQueue)
        let exported = try exporter.export()

        // Re-import into fresh database
        let db2 = try DatabaseManager(inMemory: true)
        let parser = GEDCOMParser()
        let result = parser.parse(content: exported)
        try parser.importToDatabase(result, dbQueue: db2.dbQueue)

        let reimported = try db2.dbQueue.read { database in
            try Person.fetchAll(database)
        }

        XCTAssertEqual(reimported.count, people.count, "Round-trip should preserve all \(people.count) people")

        // Verify key people survived
        XCTAssertTrue(reimported.contains { $0.firstName == "Robert" && $0.lastName == "Smith" })
        XCTAssertTrue(reimported.contains { $0.firstName == "Michael" && $0.lastName == "Smith" })
        XCTAssertTrue(reimported.contains { $0.firstName == "Jessica" && $0.lastName == "Wilson" })
        XCTAssertTrue(reimported.contains { $0.firstName == "Christopher" && $0.lastName == "Jones" })
    }
}
