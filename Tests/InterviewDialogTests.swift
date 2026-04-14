import XCTest
import GRDB
@testable import KinFlash

/// Simulates the entire interview flow: feeds the sample family one person at a time
/// through InterviewService, then exports GEDCOM and verifies against the original.
final class InterviewDialogTests: XCTestCase {

    /// Simulate building the 25-person sample family through interview extraction.
    /// Each "turn" provides one person or group with their relationships.
    func testBuildEntireFamilyViaInterview() throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // Turn 1: Root person
        let john = ExtractedPerson(firstName: "John", lastName: "Smith", role: "self")
        let savedJohn = try service.saveExtractedPerson(john)
        try setRoot(db: db, id: savedJohn.id)

        // Turn 2: Wife
        let mary = ExtractedPerson(firstName: "Mary", lastName: "Jones", role: "spouse", relatedTo: "John")
        _ = try service.saveExtractedPerson(mary)

        // Turn 3: John's parents
        let robert = ExtractedPerson(firstName: "Robert", lastName: "Smith", role: "parent", relatedTo: "John")
        _ = try service.saveExtractedPerson(robert)
        let helen = ExtractedPerson(firstName: "Helen", lastName: "Brown", role: "parent", relatedTo: "John")
        _ = try service.saveExtractedPerson(helen)

        // Turn 4: Mary's parents
        let william = ExtractedPerson(firstName: "William", lastName: "Jones", role: "parent", relatedTo: "Mary")
        _ = try service.saveExtractedPerson(william)
        let margaret = ExtractedPerson(firstName: "Margaret", lastName: "OBrien", role: "parent", relatedTo: "Mary")
        _ = try service.saveExtractedPerson(margaret)

        // Turn 5: John's siblings
        let carol = ExtractedPerson(firstName: "Carol", lastName: "Smith", role: "sibling", relatedTo: "John")
        _ = try service.saveExtractedPerson(carol)
        let david = ExtractedPerson(firstName: "David", lastName: "Smith", role: "sibling", relatedTo: "John")
        _ = try service.saveExtractedPerson(david)

        // Turn 6: Mary's sibling
        let thomas = ExtractedPerson(firstName: "Thomas", lastName: "Jones", role: "sibling", relatedTo: "Mary")
        _ = try service.saveExtractedPerson(thomas)

        // Turn 7: John + Mary's children
        let michael = ExtractedPerson(firstName: "Michael", lastName: "Smith", role: "child", relatedTo: "John")
        _ = try service.saveExtractedPerson(michael)
        let sarah = ExtractedPerson(firstName: "Sarah", lastName: "Smith", role: "child", relatedTo: "John")
        _ = try service.saveExtractedPerson(sarah)
        let emily = ExtractedPerson(firstName: "Emily", lastName: "Smith", role: "child", relatedTo: "John")
        _ = try service.saveExtractedPerson(emily)
        let daniel = ExtractedPerson(firstName: "Daniel", lastName: "Smith", role: "child", relatedTo: "John")
        _ = try service.saveExtractedPerson(daniel)

        // Turn 8: Carol's spouse + children
        let frank = ExtractedPerson(firstName: "Frank", lastName: "Wilson", role: "spouse", relatedTo: "Carol")
        _ = try service.saveExtractedPerson(frank)
        let jessica = ExtractedPerson(firstName: "Jessica", lastName: "Wilson", role: "child", relatedTo: "Carol")
        _ = try service.saveExtractedPerson(jessica)
        let ryan = ExtractedPerson(firstName: "Ryan", lastName: "Wilson", role: "child", relatedTo: "Carol")
        _ = try service.saveExtractedPerson(ryan)
        let nicole = ExtractedPerson(firstName: "Nicole", lastName: "Wilson", role: "child", relatedTo: "Carol")
        _ = try service.saveExtractedPerson(nicole)

        // Turn 9: David's spouse + children
        let lisa = ExtractedPerson(firstName: "Lisa", lastName: "Brown", role: "spouse", relatedTo: "David")
        _ = try service.saveExtractedPerson(lisa)
        let kevin = ExtractedPerson(firstName: "Kevin", lastName: "Smith", role: "child", relatedTo: "David")
        _ = try service.saveExtractedPerson(kevin)
        let amanda = ExtractedPerson(firstName: "Amanda", lastName: "Smith", role: "child", relatedTo: "David")
        _ = try service.saveExtractedPerson(amanda)
        let tyler = ExtractedPerson(firstName: "Tyler", lastName: "Smith", role: "child", relatedTo: "David")
        _ = try service.saveExtractedPerson(tyler)

        // Turn 10: Thomas's spouse + children
        let patricia = ExtractedPerson(firstName: "Patricia", lastName: "Davis", role: "spouse", relatedTo: "Thomas")
        _ = try service.saveExtractedPerson(patricia)
        let chris = ExtractedPerson(firstName: "Christopher", lastName: "Jones", role: "child", relatedTo: "Thomas")
        _ = try service.saveExtractedPerson(chris)
        let jennifer = ExtractedPerson(firstName: "Jennifer", lastName: "Jones", role: "child", relatedTo: "Thomas")
        _ = try service.saveExtractedPerson(jennifer)
        let matthew = ExtractedPerson(firstName: "Matthew", lastName: "Jones", role: "child", relatedTo: "Thomas")
        _ = try service.saveExtractedPerson(matthew)

        // Verify: 25 people
        let allPeople = try db.dbQueue.read { database in try Person.fetchAll(database) }
        print("[Dialog] Total people: \(allPeople.count)")
        print("[Dialog] Names: \(allPeople.map(\.displayName).sorted())")
        XCTAssertEqual(allPeople.count, 25, "Should have all 25 family members")

        // Verify key relationships
        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let savedMichael = allPeople.first { $0.firstName == "Michael" }!

        let fatherLabel = try resolver.resolve(from: savedMichael.id, to: savedJohn.id)
        XCTAssertTrue(fatherLabel?.label == "Father" || fatherLabel?.label == "Parent",
                       "John should be Michael's father/parent. Got: \(fatherLabel?.label ?? "nil")")

        let allLabels = try resolver.resolveAll(from: savedMichael.id)
        let grandparents = allLabels.filter { $0.value.label == "Grandfather" || $0.value.label == "Grandmother" }
        print("[Dialog] Michael's grandparents: \(grandparents.count)")

        // Verify relationships exist
        let rels = try db.dbQueue.read { database in try Relationship.fetchAll(database) }
        let spouseCount = rels.filter { $0.type == .spouse }.count
        let parentCount = rels.filter { $0.type == .parent }.count
        print("[Dialog] Relationships: \(spouseCount) spouse, \(parentCount) parent, \(rels.count) total")
        XCTAssertGreaterThan(spouseCount, 0, "Should have spouse relationships")
        XCTAssertGreaterThan(parentCount, 0, "Should have parent relationships")
    }

    /// Export the interview-built tree and verify it produces valid GEDCOM.
    func testExportInterviewBuiltTree() throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // Build a small family
        let root = ExtractedPerson(firstName: "Alice", lastName: "Green", role: "self")
        let savedRoot = try service.saveExtractedPerson(root)
        try setRoot(db: db, id: savedRoot.id)

        let spouse = ExtractedPerson(firstName: "Bob", lastName: "Green", role: "spouse", relatedTo: "Alice")
        _ = try service.saveExtractedPerson(spouse)

        let child1 = ExtractedPerson(firstName: "Charlie", lastName: "Green", role: "child", relatedTo: "Alice")
        _ = try service.saveExtractedPerson(child1)

        let child2 = ExtractedPerson(firstName: "Diana", lastName: "Green", role: "child", relatedTo: "Alice")
        _ = try service.saveExtractedPerson(child2)

        // Export
        let exporter = GEDCOMExporter(dbQueue: db.dbQueue)
        let exported = try exporter.export()

        print("[Dialog] Exported GEDCOM:\n\(exported)")

        // Verify structure
        XCTAssertTrue(exported.contains("Alice"))
        XCTAssertTrue(exported.contains("Bob"))
        XCTAssertTrue(exported.contains("Charlie"))
        XCTAssertTrue(exported.contains("Diana"))
        XCTAssertTrue(exported.contains("FAM"))
        XCTAssertTrue(exported.contains("HUSB") || exported.contains("WIFE"))
        XCTAssertTrue(exported.contains("CHIL"))

        // Reimport and verify
        let parser = GEDCOMParser()
        let reimported = parser.parse(content: exported)
        XCTAssertEqual(reimported.people.count, 4)
    }

    /// Compare interview-built tree export against GEDCOM import of the same family.
    func testInterviewMatchesGEDCOMImport() throws {
        // Method 1: Build via interview
        let db1 = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db1.dbQueue, aiProvider: provider)

        let root = ExtractedPerson(firstName: "John", lastName: "Smith", role: "self")
        let savedRoot = try service.saveExtractedPerson(root)
        try setRoot(db: db1, id: savedRoot.id)
        let _ = try service.saveExtractedPerson(
            ExtractedPerson(firstName: "Mary", lastName: "Jones", role: "spouse", relatedTo: "John"))
        let _ = try service.saveExtractedPerson(
            ExtractedPerson(firstName: "Michael", lastName: "Smith", role: "child", relatedTo: "John"))

        let interviewPeople = try db1.dbQueue.read { database in try Person.fetchAll(database) }

        // Method 2: Import same people from GEDCOM
        let gedcom = """
        0 HEAD
        1 SOUR Test
        1 GEDC
        2 VERS 5.5.1
        0 @I1@ INDI
        1 NAME John /Smith/
        1 SEX M
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME Mary /Jones/
        1 SEX F
        1 FAMS @F1@
        0 @I3@ INDI
        1 NAME Michael /Smith/
        1 SEX M
        1 FAMC @F1@
        0 @F1@ FAM
        1 HUSB @I1@
        1 WIFE @I2@
        1 CHIL @I3@
        0 TRLR
        """
        let db2 = try DatabaseManager(inMemory: true)
        let parser = GEDCOMParser()
        let result = parser.parse(content: gedcom)
        try parser.importToDatabase(result, dbQueue: db2.dbQueue)

        let gedcomPeople = try db2.dbQueue.read { database in try Person.fetchAll(database) }

        // Compare
        XCTAssertEqual(interviewPeople.count, gedcomPeople.count,
                       "Interview and GEDCOM should produce same number of people")

        let interviewNames = Set(interviewPeople.map { "\($0.firstName) \($0.lastName ?? "")" })
        let gedcomNames = Set(gedcomPeople.map { "\($0.firstName) \($0.lastName ?? "")" })
        XCTAssertEqual(interviewNames, gedcomNames,
                       "Same names from both methods")
    }

    // MARK: - Helpers

    private func setRoot(db: DatabaseManager, id: UUID) throws {
        try { try db.dbQueue.write { database in
            var settings = try AppSettings.current(database)
            settings.rootPersonId = id
            try settings.update(database)
        } }()
    }
}
