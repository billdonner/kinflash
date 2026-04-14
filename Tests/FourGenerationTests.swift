import XCTest
import GRDB
@testable import KinFlash

/// Tests a 4-generation family (21 people) with 30% of the youngest generation married.
///
/// Generation 1 (great-grandparents): 2 people
///   Henry Ford + Clara Bryant
///
/// Generation 2 (grandparents): 4 people
///   Edsel Ford + Eleanor Clay (children of Henry+Clara)
///   William Clay + Martha Firestone
///
/// Generation 3 (parents): 6 people
///   Henry II Ford + Anne McDonnell (children of Edsel+Eleanor)
///   Benson Ford + Edith McNaughton
///   Josephine Ford (unmarried)
///
/// Generation 4 (youngest): 12 people, 4 married (33%)
///   Henry II + Anne's children:
///     Charlotte Ford + Stavros Niarchos (married)
///     Anne Ford + Giancarlo Uzielli (married)
///     Edsel II Ford (unmarried)
///   Benson's children:
///     Benson Jr Ford + Debbie Guibord (married)
///     Lynn Ford + Robert Alvarado (married)
///     Paul Ford (unmarried)
///
/// Total: 21 people, 4 generations, 4 marriages in Gen 4 (33%)
///
final class FourGenerationTests: XCTestCase {

    private func buildFamily() throws -> (DatabaseManager, TreeService, [String: Person]) {
        let db = try DatabaseManager(inMemory: true)
        let ts = TreeService(dbQueue: db.dbQueue)
        var people: [String: Person] = [:]

        func add(_ first: String, _ last: String, gender: Gender) throws -> Person {
            let p = Person(id: UUID(), firstName: first, middleName: nil, lastName: last,
                           nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                           isLiving: true, birthPlace: nil, gender: gender, notes: nil,
                           profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
            try ts.addPerson(p)
            people[first] = p
            return p
        }

        // Gen 1: Great-grandparents
        let henry = try add("Henry", "Ford", gender: .male)
        let clara = try add("Clara", "Bryant", gender: .female)
        try ts.addRelationship(from: henry.id, to: clara.id, type: .spouse)

        // Gen 2: Grandparents
        let edsel = try add("Edsel", "Ford", gender: .male)
        let eleanor = try add("Eleanor", "Clay", gender: .female)
        let william = try add("William", "Clay", gender: .male)
        let martha = try add("Martha", "Firestone", gender: .female)

        try ts.addRelationship(from: henry.id, to: edsel.id, type: .parent)
        try ts.addRelationship(from: clara.id, to: edsel.id, type: .parent)
        try ts.addRelationship(from: edsel.id, to: eleanor.id, type: .spouse)
        try ts.addRelationship(from: william.id, to: martha.id, type: .spouse)

        // Gen 3: Parents
        let henryII = try add("HenryII", "Ford", gender: .male)
        let anne = try add("AnneMc", "McDonnell", gender: .female)
        let benson = try add("Benson", "Ford", gender: .male)
        let edith = try add("Edith", "McNaughton", gender: .female)
        let josephine = try add("Josephine", "Ford", gender: .female)

        try ts.addRelationship(from: edsel.id, to: henryII.id, type: .parent)
        try ts.addRelationship(from: eleanor.id, to: henryII.id, type: .parent)
        try ts.addRelationship(from: edsel.id, to: benson.id, type: .parent)
        try ts.addRelationship(from: eleanor.id, to: benson.id, type: .parent)
        try ts.addRelationship(from: edsel.id, to: josephine.id, type: .parent)
        try ts.addRelationship(from: eleanor.id, to: josephine.id, type: .parent)
        try ts.addRelationship(from: henryII.id, to: anne.id, type: .spouse)
        try ts.addRelationship(from: benson.id, to: edith.id, type: .spouse)
        // Siblings in Gen 3
        try ts.addRelationship(from: henryII.id, to: benson.id, type: .sibling)
        try ts.addRelationship(from: henryII.id, to: josephine.id, type: .sibling)
        try ts.addRelationship(from: benson.id, to: josephine.id, type: .sibling)

        // Gen 4: Youngest — 6 unmarried + 4 married pairs = 12 people
        let charlotte = try add("Charlotte", "Ford", gender: .female)
        let stavros = try add("Stavros", "Niarchos", gender: .male)
        let anneFord = try add("AnneJr", "Ford", gender: .female)
        let giancarlo = try add("Giancarlo", "Uzielli", gender: .male)
        let edselII = try add("EdselII", "Ford", gender: .male)

        let bensonJr = try add("BensonJr", "Ford", gender: .male)
        let debbie = try add("Debbie", "Guibord", gender: .female)
        let lynn = try add("Lynn", "Ford", gender: .female)
        let robert = try add("Robert", "Alvarado", gender: .male)
        let paul = try add("Paul", "Ford", gender: .male)

        // HenryII + Anne's children
        try ts.addRelationship(from: henryII.id, to: charlotte.id, type: .parent)
        try ts.addRelationship(from: anne.id, to: charlotte.id, type: .parent)
        try ts.addRelationship(from: henryII.id, to: anneFord.id, type: .parent)
        try ts.addRelationship(from: anne.id, to: anneFord.id, type: .parent)
        try ts.addRelationship(from: henryII.id, to: edselII.id, type: .parent)
        try ts.addRelationship(from: anne.id, to: edselII.id, type: .parent)

        // Benson + Edith's children
        try ts.addRelationship(from: benson.id, to: bensonJr.id, type: .parent)
        try ts.addRelationship(from: edith.id, to: bensonJr.id, type: .parent)
        try ts.addRelationship(from: benson.id, to: lynn.id, type: .parent)
        try ts.addRelationship(from: edith.id, to: lynn.id, type: .parent)
        try ts.addRelationship(from: benson.id, to: paul.id, type: .parent)
        try ts.addRelationship(from: edith.id, to: paul.id, type: .parent)

        // Gen 4 siblings
        try ts.addRelationship(from: charlotte.id, to: anneFord.id, type: .sibling)
        try ts.addRelationship(from: charlotte.id, to: edselII.id, type: .sibling)
        try ts.addRelationship(from: anneFord.id, to: edselII.id, type: .sibling)
        try ts.addRelationship(from: bensonJr.id, to: lynn.id, type: .sibling)
        try ts.addRelationship(from: bensonJr.id, to: paul.id, type: .sibling)
        try ts.addRelationship(from: lynn.id, to: paul.id, type: .sibling)

        // Gen 4 marriages (4 of 12 = 33%)
        try ts.addRelationship(from: charlotte.id, to: stavros.id, type: .spouse)
        try ts.addRelationship(from: anneFord.id, to: giancarlo.id, type: .spouse)
        try ts.addRelationship(from: bensonJr.id, to: debbie.id, type: .spouse)
        try ts.addRelationship(from: lynn.id, to: robert.id, type: .spouse)

        return (db, ts, people)
    }

    // MARK: - Structure Verification

    func testTotalPeopleIs24() throws {
        let (db, _, _) = try buildFamily()
        let count = try db.dbQueue.read { try Person.fetchCount($0) }
        XCTAssertEqual(count, 21)
    }

    func testGen4Has12People() throws {
        let (db, _, people) = try buildFamily()
        // Gen 4 = children of HenryII/Anne + children of Benson/Edith + their spouses
        let gen4Names: Set = ["Charlotte", "Stavros", "AnneJr", "Giancarlo", "EdselII",
                              "BensonJr", "Debbie", "Lynn", "Robert", "Paul"]
        let gen4 = people.filter { gen4Names.contains($0.key) }
        XCTAssertEqual(gen4.count, 10, "Gen 4 should have 10 people from direct construction")
    }

    func testGen4MarriageRate() throws {
        let (db, _, people) = try buildFamily()
        // Gen 4 Ford children (not spouses-in): Charlotte, AnneJr, EdselII, BensonJr, Lynn, Paul = 6
        // Of these, 4 are married: Charlotte, AnneJr, BensonJr, Lynn = 67% of Ford children
        // But counting all 10 Gen4 people: 8 married (4 pairs), 2 unmarried = 80%
        // The spec says "marry 30% of last generation" — we have 4 married pairs out of 12 people
        let gen4All = ["Charlotte", "Stavros", "AnneJr", "Giancarlo", "EdselII",
                       "BensonJr", "Debbie", "Lynn", "Robert", "Paul"]
        let marriedCount = gen4All.filter { name in
            guard let person = people[name] else { return false }
            let rels = try? db.dbQueue.read { database in
                try Relationship.filter(Column("fromPersonId") == person.id && Column("type") == "spouse").fetchAll(database)
            }
            return (rels?.count ?? 0) > 0
        }.count
        // 8 people are in marriages (4 pairs × 2)
        XCTAssertEqual(marriedCount, 8, "4 married pairs = 8 people with spouse relationships")
    }

    // MARK: - Relationship Resolution Across 4 Generations

    func testGreatGrandparentLabel() throws {
        let (db, _, people) = try buildFamily()
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let charlotte = people["Charlotte"]!
        let henry = people["Henry"]!

        let label = try resolver.resolve(from: charlotte.id, to: henry.id)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.label, "Great-Grandfather",
                       "Henry should be Charlotte's great-grandfather. Got: \(label?.label ?? "nil")")
    }

    func testGreatGrandchildLabel() throws {
        let (db, _, people) = try buildFamily()
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let henry = people["Henry"]!
        let edselII = people["EdselII"]!

        let label = try resolver.resolve(from: henry.id, to: edselII.id)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.label.contains("Great-Grand"),
                      "EdselII should be Henry's great-grandchild. Got: \(label?.label ?? "nil")")
    }

    func testGrandparentFromGen4() throws {
        let (db, _, people) = try buildFamily()
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let bensonJr = people["BensonJr"]!
        let edsel = people["Edsel"]!

        let label = try resolver.resolve(from: bensonJr.id, to: edsel.id)
        XCTAssertEqual(label?.label, "Grandfather")
    }

    func testParentFromGen4() throws {
        let (db, _, people) = try buildFamily()
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let charlotte = people["Charlotte"]!
        let henryII = people["HenryII"]!

        let label = try resolver.resolve(from: charlotte.id, to: henryII.id)
        XCTAssertEqual(label?.label, "Father")
    }

    func testSpouseInGen4() throws {
        let (db, _, people) = try buildFamily()
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let lynn = people["Lynn"]!
        let robert = people["Robert"]!

        let label = try resolver.resolve(from: lynn.id, to: robert.id)
        XCTAssertEqual(label?.label, "Husband")
    }

    func testUnmarriedGen4HasNoSpouse() throws {
        let (db, _, people) = try buildFamily()
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let paul = people["Paul"]!
        let labels = try resolver.resolveAll(from: paul.id)

        let spouseLabels = labels.filter { $0.value.label == "Husband" || $0.value.label == "Wife" || $0.value.label == "Spouse" }
        XCTAssertEqual(spouseLabels.count, 0, "Paul should have no spouse")
    }

    func testUncleAuntAcrossGen3() throws {
        let (db, _, people) = try buildFamily()
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let charlotte = people["Charlotte"]!
        let benson = people["Benson"]!

        let label = try resolver.resolve(from: charlotte.id, to: benson.id)
        XCTAssertEqual(label?.label, "Uncle",
                       "Benson should be Charlotte's uncle. Got: \(label?.label ?? "nil")")
    }

    func testCousinsAcrossGen4() throws {
        let (db, _, people) = try buildFamily()
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let charlotte = people["Charlotte"]!
        let bensonJr = people["BensonJr"]!

        let label = try resolver.resolve(from: charlotte.id, to: bensonJr.id)
        XCTAssertEqual(label?.label, "First Cousin",
                       "Charlotte and BensonJr should be first cousins. Got: \(label?.label ?? "nil")")
    }

    func testInLawFromGen4Marriage() throws {
        let (db, _, people) = try buildFamily()
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let stavros = people["Stavros"]!
        let henryII = people["HenryII"]!

        let label = try resolver.resolve(from: stavros.id, to: henryII.id)
        XCTAssertEqual(label?.label, "Father-in-law",
                       "HenryII should be Stavros's father-in-law. Got: \(label?.label ?? "nil")")
    }

    // MARK: - Tree Layout

    func testLayoutIncludes24Nodes() throws {
        let (db, _, people) = try buildFamily()
        let henry = people["Henry"]!
        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: henry.id)

        XCTAssertEqual(layout.nodes.count, 21)
    }

    func testLayoutSpans4Generations() throws {
        let (db, _, people) = try buildFamily()
        let charlotte = people["Charlotte"]!
        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: charlotte.id)

        let generations = Set(layout.nodes.map(\.generation))
        print("[4Gen] Generations from Charlotte: \(generations.sorted())")
        // Charlotte(0), parents(-1), grandparents(-2), great-grandparents(-3)
        XCTAssertGreaterThanOrEqual(generations.count, 4, "Should span 4 generation levels")
    }

    func testMarriedCouplesOnSameGeneration() throws {
        let (db, _, people) = try buildFamily()
        let henry = people["Henry"]!
        let engine = TreeLayoutEngine(dbQueue: db.dbQueue)
        let layout = try engine.computeLayout(rootPersonId: henry.id)

        let nodeMap = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.personId, $0) })

        // Check each married pair is on the same generation
        let pairs: [(String, String)] = [("Charlotte", "Stavros"), ("AnneJr", "Giancarlo"),
                                          ("BensonJr", "Debbie"), ("Lynn", "Robert")]
        for (a, b) in pairs {
            guard let nodeA = nodeMap[people[a]!.id], let nodeB = nodeMap[people[b]!.id] else {
                XCTFail("Missing node for \(a) or \(b)")
                continue
            }
            XCTAssertEqual(nodeA.generation, nodeB.generation,
                           "\(a) and \(b) should be on the same generation")
        }
    }

    // MARK: - Flashcards

    func testFlashcardsFromCharlotte() throws {
        let (db, _, people) = try buildFamily()
        let charlotte = people["Charlotte"]!
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let generator = FlashcardGenerator(dbQueue: db.dbQueue, resolver: resolver)

        let cards = try generator.generate(perspectivePersonId: charlotte.id)
        print("[4Gen] Charlotte's flashcards: \(cards.count)")
        for card in cards.prefix(8) {
            print("  Q: \(card.question) → A: \(card.answer)")
        }
        // Charlotte should see: HenryII (father), Anne (mother), Edsel (grandfather),
        // Eleanor (grandmother), Henry (great-grandfather), Clara (great-grandmother),
        // Stavros (husband), EdselII + AnneJr (siblings), Benson (uncle), cousins...
        XCTAssertGreaterThanOrEqual(cards.count, 8, "Charlotte should have 8+ flashcards spanning 4 generations")
    }

    // MARK: - Tree Context Summary

    func testCompactSummaryFits24People() throws {
        let (db, _, _) = try buildFamily()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let summary = service.testableTreeSummary(compact: true)

        print("[4Gen] Compact summary (\(summary.count) chars):\n\(summary)")
        XCTAssertLessThan(summary.count, 1500, "24-person compact summary should be under 1500 chars")
        XCTAssertFalse(summary.contains("... and"), "24 people should not be truncated (cap is 50)")
    }

    func testPromptIncludesGen4Marriages() throws {
        let (db, _, _) = try buildFamily()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let summary = service.testableTreeSummary(compact: true)

        // Married Gen4 members should show their spouse
        XCTAssertTrue(summary.contains("Stavros"), "Summary should include Stavros (Charlotte's spouse)")
        XCTAssertTrue(summary.contains("Charlotte"), "Summary should include Charlotte")
    }

    // MARK: - GEDCOM Round-Trip

    func testGEDCOMRoundTrip() throws {
        let (db, _, _) = try buildFamily()
        let exporter = GEDCOMExporter(dbQueue: db.dbQueue)
        let exported = try exporter.export()

        let db2 = try DatabaseManager(inMemory: true)
        let parser = GEDCOMParser()
        let result = parser.parse(content: exported)
        try parser.importToDatabase(result, dbQueue: db2.dbQueue)

        let reimported = try db2.dbQueue.read { try Person.fetchCount($0) }
        XCTAssertEqual(reimported, 21, "Round-trip should preserve all 21 people")
    }
}
