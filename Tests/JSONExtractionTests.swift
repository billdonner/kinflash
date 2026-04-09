import XCTest
import GRDB
@testable import KinFlash

final class JSONExtractionTests: XCTestCase {

    // MARK: - Array extraction (model wraps multiple people in [...])

    func testExtractJSONArray() {
        let text = """
        Hi!

        ```json
        [
          {"firstName":"Tom","lastName":"Smith","role":"child"},
          {"firstName":"Sue","lastName":"Smith","role":"spouse"}
        ]
        ```

        Want to add more?
        """
        let people = extractAll(from: text)
        XCTAssertEqual(people.count, 2)
        XCTAssertTrue(people.contains { $0.firstName == "Tom" })
        XCTAssertTrue(people.contains { $0.firstName == "Sue" })
    }

    func testExtractSeparateBlocks() {
        let text = """
        Got it!

        ```json
        {"firstName":"Bob","lastName":"Jones","role":"parent"}
        ```

        ```json
        {"firstName":"Alice","lastName":"Jones","role":"parent"}
        ```
        """
        let people = extractAll(from: text)
        XCTAssertEqual(people.count, 2)
    }

    func testExtractSingleObject() {
        let text = """
        ```json
        {"firstName":"Brutus","lastName":"Maximus","role":"self"}
        ```
        """
        let people = extractAll(from: text)
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].firstName, "Brutus")
        XCTAssertEqual(people[0].role, "self")
    }

    func testExtractMinimalFields() {
        // Model might only output firstName and lastName
        let text = """
        ```json
        {"firstName":"Jane","lastName":"Doe"}
        ```
        """
        let people = extractAll(from: text)
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].firstName, "Jane")
        XCTAssertNil(people[0].role)
    }

    func testExtractWithExtraWordsAfterJson() {
        // Model might add words after ```json
        let text = """
        ```json fences
        {"firstName":"Test","lastName":"User","role":"self"}
        ```
        """
        let people = extractAll(from: text)
        XCTAssertEqual(people.count, 1)
    }

    func testNoJSONReturnsEmpty() {
        let text = "Just a friendly message with no data."
        let people = extractAll(from: text)
        XCTAssertEqual(people.count, 0)
    }

    func testMalformedJSONSkipped() {
        let text = """
        ```json
        {"firstName": broken json here
        ```
        """
        let people = extractAll(from: text)
        XCTAssertEqual(people.count, 0)
    }

    func testExtractJSONLines() {
        // Model puts multiple objects on separate lines without array brackets
        let text = """
        Got it!

        ```json
        {"firstName":"Adam","lastName":"Smith","role":"parent"}
        {"firstName":"Eve","lastName":"Smith","role":"parent"}
        ```

        Anyone else?
        """
        let people = extractAll(from: text)
        XCTAssertEqual(people.count, 2, "Should parse JSON Lines (newline-separated objects)")
        XCTAssertTrue(people.contains { $0.firstName == "Adam" })
        XCTAssertTrue(people.contains { $0.firstName == "Eve" })
    }

    func testMixedValidAndInvalidBlocks() {
        let text = """
        ```json
        {"firstName":"Good","lastName":"Person","role":"self"}
        ```

        ```json
        not valid json
        ```

        ```json
        {"firstName":"Also","lastName":"Good","role":"child"}
        ```
        """
        let people = extractAll(from: text)
        XCTAssertEqual(people.count, 2)
    }

    // MARK: - Role-based linking

    func testRoleLinkingParent() throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // Create root person
        let root = ExtractedPerson(firstName: "Root", lastName: "Person", role: "self")
        let savedRoot = try service.saveExtractedPerson(root)

        // Set as root
        try db.dbQueue.write { database in
            var settings = try AppSettings.current(database)
            settings.rootPersonId = savedRoot.id
            settings.updatedAt = Date()
            try settings.update(database)
        }

        // Add parent
        let parent = ExtractedPerson(firstName: "Dad", lastName: "Person", role: "parent")
        let savedParent = try service.saveExtractedPerson(parent)

        // Verify relationship: Dad is parent of Root
        let rels = try db.dbQueue.read { database in
            try Relationship.filter(Column("type") == "parent").fetchAll(database)
        }
        XCTAssertEqual(rels.count, 1)
        XCTAssertEqual(rels[0].fromPersonId, savedParent.id)
        XCTAssertEqual(rels[0].toPersonId, savedRoot.id)
    }

    func testRoleLinkingSpouse() throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let root = ExtractedPerson(firstName: "Root", lastName: "Person", role: "self")
        let savedRoot = try service.saveExtractedPerson(root)
        try db.dbQueue.write { database in
            var settings = try AppSettings.current(database)
            settings.rootPersonId = savedRoot.id
            try settings.update(database)
        }

        let spouse = ExtractedPerson(firstName: "Spouse", lastName: "Person", role: "spouse")
        _ = try service.saveExtractedPerson(spouse)

        let rels = try db.dbQueue.read { database in
            try Relationship.filter(Column("type") == "spouse").fetchAll(database)
        }
        XCTAssertEqual(rels.count, 2, "Spouse should create bidirectional rows")
    }

    func testRoleLinkingChild() throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let root = ExtractedPerson(firstName: "Root", lastName: "Person", role: "self")
        let savedRoot = try service.saveExtractedPerson(root)
        try db.dbQueue.write { database in
            var settings = try AppSettings.current(database)
            settings.rootPersonId = savedRoot.id
            try settings.update(database)
        }

        let child = ExtractedPerson(firstName: "Kid", lastName: "Person", role: "child")
        let savedChild = try service.saveExtractedPerson(child)

        let rels = try db.dbQueue.read { database in
            try Relationship.filter(Column("type") == "parent").fetchAll(database)
        }
        XCTAssertEqual(rels.count, 1)
        XCTAssertEqual(rels[0].fromPersonId, savedRoot.id, "Root should be parent")
        XCTAssertEqual(rels[0].toPersonId, savedChild.id, "Kid should be child")
    }

    func testSelfRoleCreatesNoRelationship() throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let person = ExtractedPerson(firstName: "Me", lastName: "Myself", role: "self")
        _ = try service.saveExtractedPerson(person)

        let rels = try db.dbQueue.read { database in
            try Relationship.fetchCount(database)
        }
        XCTAssertEqual(rels, 0, "Self role should not create any relationship")
    }

    // MARK: - CleanResponse

    func testCleanResponseRemovesJSONBlock() {
        let text = """
        Hello!

        ```json
        {"firstName":"Test"}
        ```

        Want more?
        """
        let cleaned = cleanResponse(text)
        XCTAssertFalse(cleaned.contains("firstName"))
        XCTAssertTrue(cleaned.contains("Hello"))
        XCTAssertTrue(cleaned.contains("Want more"))
    }

    func testCleanResponseRemovesMetaPhrases() {
        let cleaned = cleanResponse("Here's your JSON block: some text")
        XCTAssertFalse(cleaned.contains("JSON block"))
    }

    func testCleanResponseEmptyAfterStrip() {
        let text = """
        ```json
        {"firstName":"Only"}
        ```
        """
        let cleaned = cleanResponse(text)
        XCTAssertTrue(cleaned.isEmpty)
    }

    // MARK: - Helpers (duplicated from InterviewView for testing)

    private func extractAll(from text: String) -> [ExtractedPerson] {
        let pattern = #"```json[^\n]*\n([\s\S]*?)\n\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        var results: [ExtractedPerson] = []
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let jsonStr = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = jsonStr.data(using: .utf8) else { continue }
            if let person = try? JSONDecoder().decode(ExtractedPerson.self, from: data) {
                results.append(person)
            } else if let people = try? JSONDecoder().decode([ExtractedPerson].self, from: data) {
                results.append(contentsOf: people)
            } else {
                // JSON Lines: multiple objects on separate lines
                for line in jsonStr.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("{"), let lineData = trimmed.data(using: .utf8) else { continue }
                    if let person = try? JSONDecoder().decode(ExtractedPerson.self, from: lineData) {
                        results.append(person)
                    }
                }
            }
        }
        return results
    }

    private func cleanResponse(_ text: String) -> String {
        var cleaned = text
        if let regex = try? NSRegularExpression(pattern: #"```json[^\n]*\n[\s\S]*?```"#) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: #"```json[^\n]*[\s\S]*$"#) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }
        cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        for phrase in ["Here's your JSON block:", "Here's the JSON block:",
                       "Here are your JSON blocks:", "I've extracted the following family members:",
                       "I've extracted the following:", "Here's the extracted data:"] {
            cleaned = cleaned.replacingOccurrences(of: phrase, with: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
