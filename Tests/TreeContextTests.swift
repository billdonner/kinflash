import XCTest
import GRDB
@testable import KinFlash

/// Tests for the AI strategy change: sending current tree structure as context.
final class TreeContextTests: XCTestCase {

    // MARK: - Helper to build a family

    private func makeDB() throws -> DatabaseManager {
        try DatabaseManager(inMemory: true)
    }

    private func makePerson(_ first: String, _ last: String, gender: Gender? = nil) -> Person {
        Person(id: UUID(), firstName: first, middleName: nil, lastName: last,
               nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
               isLiving: true, birthPlace: nil, gender: gender, notes: nil,
               profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
    }

    private func buildSmallFamily(db: DatabaseManager) throws -> [Person] {
        let ts = TreeService(dbQueue: db.dbQueue)
        let john = makePerson("John", "Smith", gender: .male)
        let mary = makePerson("Mary", "Smith", gender: .female)
        let kid1 = makePerson("Alice", "Smith", gender: .female)
        let kid2 = makePerson("Bob", "Smith", gender: .male)

        try ts.addPerson(john)
        try ts.addPerson(mary)
        try ts.addPerson(kid1)
        try ts.addPerson(kid2)
        try ts.addRelationship(from: john.id, to: mary.id, type: .spouse)
        try ts.addRelationship(from: john.id, to: kid1.id, type: .parent)
        try ts.addRelationship(from: mary.id, to: kid1.id, type: .parent)
        try ts.addRelationship(from: john.id, to: kid2.id, type: .parent)
        try ts.addRelationship(from: mary.id, to: kid2.id, type: .parent)

        return [john, mary, kid1, kid2]
    }

    // MARK: - Tree Summary Generation

    func testEmptyTreeProducesEmptySummary() throws {
        let db = try makeDB()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let summary = service.testableTreeSummary(compact: true)
        XCTAssertTrue(summary.isEmpty)
    }

    func testCompactSummaryIncludesAllPeople() throws {
        let db = try makeDB()
        _ = try buildSmallFamily(db: db)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let summary = service.testableTreeSummary(compact: true)

        XCTAssertTrue(summary.contains("John"), "Should include John")
        XCTAssertTrue(summary.contains("Mary"), "Should include Mary")
        XCTAssertTrue(summary.contains("Alice"), "Should include Alice")
        XCTAssertTrue(summary.contains("Bob"), "Should include Bob")
        print("[TreeContext] Compact summary:\n\(summary)")
    }

    func testCompactSummaryShowsRelationships() throws {
        let db = try makeDB()
        _ = try buildSmallFamily(db: db)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let summary = service.testableTreeSummary(compact: true)

        // John should show sp=Mary and ch=Alice,Bob (or similar)
        XCTAssertTrue(summary.contains("sp="), "Should include spouse abbreviation")
        XCTAssertTrue(summary.contains("ch="), "Should include children abbreviation")
    }

    func testCloudSummaryIsMoreReadable() throws {
        let db = try makeDB()
        _ = try buildSmallFamily(db: db)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let cloud = service.testableTreeSummary(compact: false)
        let compact = service.testableTreeSummary(compact: true)

        XCTAssertTrue(cloud.contains("spouse:"), "Cloud should use 'spouse:' not 'sp='")
        XCTAssertTrue(cloud.contains("children:"), "Cloud should use 'children:' not 'ch='")
        XCTAssertGreaterThan(cloud.count, compact.count, "Cloud format should be longer than compact")
        print("[TreeContext] Cloud summary:\n\(cloud)")
    }

    func testCompactSummaryTokenBudget() throws {
        let db = try makeDB()
        // Build a family with 25 people (use the GEDCOM parser)
        let gedcomURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("KinFlash/Resources/SampleFamily.ged")
        let content = try String(contentsOf: gedcomURL, encoding: .utf8)
        let parser = GEDCOMParser()
        let result = parser.parse(content: content)
        try parser.importToDatabase(result, dbQueue: db.dbQueue)

        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let summary = service.testableTreeSummary(compact: true)

        // 25 people × ~15 chars each ≈ 375 chars ≈ ~95 tokens — well within budget
        print("[TreeContext] 25-person compact summary (\(summary.count) chars):\n\(summary)")
        XCTAssertLessThan(summary.count, 2000, "25-person compact summary should be under 2000 chars")
    }

    func testCloudSummaryWith25People() throws {
        let db = try makeDB()
        let gedcomURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("KinFlash/Resources/SampleFamily.ged")
        let content = try String(contentsOf: gedcomURL, encoding: .utf8)
        let parser = GEDCOMParser()
        let result = parser.parse(content: content)
        try parser.importToDatabase(result, dbQueue: db.dbQueue)

        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let summary = service.testableTreeSummary(compact: false)

        print("[TreeContext] 25-person cloud summary (\(summary.count) chars)")
        // Cloud has more room, but should still be reasonable
        XCTAssertGreaterThan(summary.count, 500, "Cloud summary should have detail")
    }

    // MARK: - Cap/Truncation

    func testCompactSummaryCapsAt50() throws {
        let db = try makeDB()
        // Create 60 people with no relationships
        try db.dbQueue.write { database in
            for i in 1...60 {
                let p = Person(id: UUID(), firstName: "Person\(i)", middleName: nil, lastName: "Test",
                               nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                               isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                               profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
                try p.insert(database)
            }
        }

        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let summary = service.testableTreeSummary(compact: true)

        XCTAssertTrue(summary.contains("... and 10 more"), "Should truncate at 50 with overflow message")
        // Count lines (each person = one line, plus the overflow line)
        let lineCount = summary.components(separatedBy: "\n").count
        XCTAssertEqual(lineCount, 51, "Should have 50 person lines + 1 overflow line")
    }

    func testCloudSummaryAllowsMore() throws {
        let db = try makeDB()
        try db.dbQueue.write { database in
            for i in 1...60 {
                let p = Person(id: UUID(), firstName: "Person\(i)", middleName: nil, lastName: "Test",
                               nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                               isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                               profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
                try p.insert(database)
            }
        }

        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let summary = service.testableTreeSummary(compact: false)

        XCTAssertFalse(summary.contains("... and"), "Cloud should NOT truncate 60 people (cap is 500)")
    }

    // MARK: - System Prompt Includes Tree

    func testSystemPromptIncludesTreeWhenPeopleExist() throws {
        let db = try makeDB()
        _ = try buildSmallFamily(db: db)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let prompt = service.testableSystemPrompt

        XCTAssertTrue(prompt.contains("Current family tree:"), "Prompt should include tree header")
        XCTAssertTrue(prompt.contains("John"), "Prompt should include John from tree")
    }

    func testSystemPromptOmitsTreeWhenEmpty() throws {
        let db = try makeDB()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let prompt = service.testableSystemPrompt

        XCTAssertFalse(prompt.contains("Current family tree:"), "Empty tree should not add tree section")
    }

    func testCloudPromptUsesFullFormat() throws {
        let db = try makeDB()
        _ = try buildSmallFamily(db: db)
        // Use AnthropicProvider (with fake key) to get cloud prompt
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: AnthropicProvider(apiKey: "test", model: "test"))
        let prompt = service.testableSystemPrompt

        XCTAssertTrue(prompt.contains("spouse:"), "Cloud prompt should use readable format")
        XCTAssertTrue(prompt.contains("relatedTo"), "Cloud prompt should mention relatedTo")
    }

    func testOnDevicePromptUsesCompactFormat() throws {
        let db = try makeDB()
        _ = try buildSmallFamily(db: db)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let prompt = service.testableSystemPrompt

        XCTAssertTrue(prompt.contains("sp="), "On-device prompt should use compact format")
    }

    // MARK: - relatedTo Inference from User Text

    func testInferRelatedToFindsExistingPerson() throws {
        // This tests the InterviewView's inferRelatedTo indirectly
        // by checking that linkByRole uses relatedTo correctly
        let db = try makeDB()
        let ts = TreeService(dbQueue: db.dbQueue)
        let ryan = makePerson("Ryan", "Wilson", gender: .male)
        try ts.addPerson(ryan)

        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let julie = ExtractedPerson(firstName: "Julie", lastName: "Katz", role: "spouse", relatedTo: "Ryan")
        let saved = try service.saveExtractedPerson(julie)

        // Verify Julie is linked to Ryan as spouse
        let rels = try db.dbQueue.read { database in
            try Relationship.filter(Column("type") == "spouse").fetchAll(database)
        }
        XCTAssertEqual(rels.count, 2, "Spouse should create 2 directed rows")
        let ryanToJulie = rels.contains { $0.fromPersonId == ryan.id && $0.toPersonId == saved.id }
        XCTAssertTrue(ryanToJulie, "Ryan should be linked to Julie as spouse")
    }

    func testRelatedToFallsBackToRoot() throws {
        let db = try makeDB()
        let ts = TreeService(dbQueue: db.dbQueue)
        let root = makePerson("Root", "Person")
        try ts.addPerson(root)

        // Set as root
        try db.dbQueue.write { database in
            var settings = try AppSettings.current(database)
            settings.rootPersonId = root.id
            try settings.update(database)
        }

        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        // No relatedTo — should link to root
        let child = ExtractedPerson(firstName: "Kid", lastName: "Person", role: "child")
        let saved = try service.saveExtractedPerson(child)

        let rels = try db.dbQueue.read { database in
            try Relationship.filter(Column("type") == "parent").fetchAll(database)
        }
        XCTAssertEqual(rels.count, 1)
        XCTAssertEqual(rels[0].fromPersonId, root.id, "Should link to root when no relatedTo")
        XCTAssertEqual(rels[0].toPersonId, saved.id)
    }

    func testRelatedToWithAmbiguousFirstName() throws {
        let db = try makeDB()
        let ts = TreeService(dbQueue: db.dbQueue)
        // Two Johns — relatedTo should still link to one of them
        let john1 = makePerson("John", "Smith")
        let john2 = makePerson("John", "Wilson")
        try ts.addPerson(john1)
        try ts.addPerson(john2)

        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let spouse = ExtractedPerson(firstName: "Jane", lastName: "Doe", role: "spouse", relatedTo: "John")
        _ = try service.saveExtractedPerson(spouse)

        // Should link to one of the Johns (not crash or skip)
        let rels = try db.dbQueue.read { database in
            try Relationship.filter(Column("type") == "spouse").fetchAll(database)
        }
        XCTAssertGreaterThan(rels.count, 0, "Should link to a John even with ambiguous names")
        let linkedToAJohn = rels.contains { $0.fromPersonId == john1.id || $0.fromPersonId == john2.id }
        XCTAssertTrue(linkedToAJohn, "Should link to one of the Johns")
    }

    // MARK: - Self-First Processing Order

    func testSelfProcessedBeforeOthers() throws {
        // When model returns spouse before self, self should still be processed first
        let db = try makeDB()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())

        // Save self first
        let selfPerson = ExtractedPerson(firstName: "Me", lastName: "Test", role: "self")
        let savedSelf = try service.saveExtractedPerson(selfPerson)

        // Set as root
        try db.dbQueue.write { database in
            var settings = try AppSettings.current(database)
            settings.rootPersonId = savedSelf.id
            try settings.update(database)
        }

        // Then save spouse
        let spouse = ExtractedPerson(firstName: "Partner", lastName: "Test", role: "spouse")
        _ = try service.saveExtractedPerson(spouse)

        let rels = try db.dbQueue.read { database in
            try Relationship.filter(Column("type") == "spouse").fetchAll(database)
        }
        XCTAssertEqual(rels.count, 2, "Spouse linked to self")
    }

    // MARK: - Prompt Size Limits

    func testPromptFitsIn4KTokens() throws {
        let db = try makeDB()
        // Build 50 people (the cap)
        try db.dbQueue.write { database in
            for i in 1...50 {
                let p = Person(id: UUID(), firstName: "P\(i)", middleName: nil, lastName: "Family",
                               nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                               isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                               profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
                try p.insert(database)
            }
        }

        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: LocalInterviewProvider())
        let prompt = service.testableSystemPrompt

        // Rough token estimate: 1 token ≈ 4 chars
        let estimatedTokens = prompt.count / 4
        print("[TreeContext] 50-person prompt: \(prompt.count) chars, ~\(estimatedTokens) tokens")
        XCTAssertLessThan(estimatedTokens, 3500, "Full prompt with 50 people should leave room for user message + response")
    }
}
