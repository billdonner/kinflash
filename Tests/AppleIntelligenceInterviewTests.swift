import XCTest
import GRDB
@testable import KinFlash

final class AppleIntelligenceInterviewTests: XCTestCase {

    /// Verify that the first user message (name) produces a JSON extraction block.
    func testNameEntryEmitsJSON() async throws {
        let provider = LocalInterviewProvider()

        // User gives their name — should get JSON back with the person
        let messages = [
            AIMessage(role: .system, content: "You are a family tree assistant."),
            AIMessage(role: .user, content: "John Smith")
        ]
        let response = try await provider.chat(messages: messages)
        let person = extractPerson(from: response)

        XCTAssertNotNil(person, "Name entry should emit a JSON block")
        XCTAssertEqual(person?.firstName, "John")
        XCTAssertEqual(person?.lastName, "Smith")
        XCTAssertEqual(person?.isComplete, true)
    }

    /// Verify that parent names produce JSON blocks with parent relationships.
    func testParentNamesEmitRelationships() async throws {
        let provider = LocalInterviewProvider()

        // Simulate conversation through to parent question
        let messages = [
            AIMessage(role: .system, content: "You are a family tree assistant."),
            AIMessage(role: .user, content: "John Smith"),
            AIMessage(role: .assistant, content: "Nice to meet you, John! What year were you born?"),
            AIMessage(role: .user, content: "1985"),
            AIMessage(role: .assistant, content: "Tell me about your parents. What are their full names?"),
            AIMessage(role: .user, content: "Richard Smith and Rose Smith")
        ]
        let response = try await provider.chat(messages: messages)
        let people = extractAllPeople(from: response)

        XCTAssertGreaterThanOrEqual(people.count, 1, "Should extract at least one parent")

        // At least one should have a parent relationship
        let withRel = people.filter { !$0.relationships.isEmpty }
        XCTAssertGreaterThanOrEqual(withRel.count, 1, "At least one parent should have a relationship link")
    }

    /// Verify the end-to-end flow: name → parents → creates tree in DB.
    func testEndToEndCreatesTreeViaInterviewService() async throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // Turn 1: name — should extract person
        let (r1, ex1) = try await service.processMessage(
            userMessage: "Jane Doe",
            conversationHistory: []
        )
        XCTAssertNotNil(ex1, "First turn (name) should extract the root person")
        if let p = ex1, p.isComplete {
            _ = try service.saveExtractedPerson(p)
        }

        // Turn 2: birth year
        let history1 = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: "Jane Doe"),
            AIMessage(role: .assistant, content: r1),
        ]
        let (r2, _) = try await service.processMessage(
            userMessage: "1990",
            conversationHistory: history1
        )

        // Turn 3: parents — should extract parent people with relationships
        let history2 = history1 + [
            AIMessage(role: .user, content: "1990"),
            AIMessage(role: .assistant, content: r2),
        ]
        let (_, ex3) = try await service.processMessage(
            userMessage: "Bob Doe and Alice Doe",
            conversationHistory: history2
        )
        // The service only returns the first extraction; the view handles multiple
        // But we can check the full response for JSON blocks

        // Verify people in DB
        let people: [Person] = try {
            try db.dbQueue.read { database in
                try Person.fetchAll(database)
            }
        }()
        XCTAssertGreaterThanOrEqual(people.count, 1, "At least the root person should exist")
        XCTAssertTrue(people.contains { $0.firstName == "Jane" }, "Jane should be in the database")
    }

    /// Verify spouse handling.
    func testSpouseExtraction() async throws {
        let provider = LocalInterviewProvider()

        let messages = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: "John Smith"),
            AIMessage(role: .assistant, content: "Nice to meet you! What year were you born?"),
            AIMessage(role: .user, content: "1960"),
            AIMessage(role: .assistant, content: "Tell me about your parents."),
            AIMessage(role: .user, content: "no"),
            AIMessage(role: .assistant, content: "Are you married or do you have a spouse or partner?"),
            AIMessage(role: .user, content: "my wife Sarah Johnson")
        ]
        let response = try await provider.chat(messages: messages)
        let people = extractAllPeople(from: response)

        let sarah = people.first { $0.firstName == "Sarah" }
        XCTAssertNotNil(sarah, "Should extract Sarah")
        XCTAssertEqual(sarah?.lastName, "Johnson")
        // Should have a spouse relationship back to John
        let spouseRel = sarah?.relationships.first { $0.type == "spouse" }
        XCTAssertNotNil(spouseRel, "Sarah should have a spouse relationship")
    }

    /// Verify children extraction.
    func testChildrenExtraction() async throws {
        let provider = LocalInterviewProvider()

        let messages = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: "John Smith"),
            AIMessage(role: .assistant, content: "Nice! Born?"),
            AIMessage(role: .user, content: "1960"),
            AIMessage(role: .assistant, content: "Parents?"),
            AIMessage(role: .user, content: "no"),
            AIMessage(role: .assistant, content: "Spouse?"),
            AIMessage(role: .user, content: "no"),
            AIMessage(role: .assistant, content: "Do you have any children? Tell me their full names."),
            AIMessage(role: .user, content: "Andrew Smith, Charlie Smith, James Smith")
        ]
        let response = try await provider.chat(messages: messages)
        let people = extractAllPeople(from: response)

        XCTAssertGreaterThanOrEqual(people.count, 3, "Should extract 3 children")
        XCTAssertTrue(people.contains { $0.firstName == "Andrew" })
        XCTAssertTrue(people.contains { $0.firstName == "Charlie" })
        XCTAssertTrue(people.contains { $0.firstName == "James" })
    }

    /// Verify grandchildren via possessive pattern ("Andrew's kids are Teddy and Max").
    func testGrandchildrenExtraction() async throws {
        let provider = LocalInterviewProvider()

        let messages = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: "John Smith"),
            AIMessage(role: .assistant, content: "Born?"),
            AIMessage(role: .user, content: "1960"),
            AIMessage(role: .assistant, content: "Parents?"),
            AIMessage(role: .user, content: "no"),
            AIMessage(role: .assistant, content: "Spouse?"),
            AIMessage(role: .user, content: "no"),
            AIMessage(role: .assistant, content: "Children?"),
            AIMessage(role: .user, content: "Andrew"),
            AIMessage(role: .assistant, content: "Siblings?"),
            AIMessage(role: .user, content: "no"),
            AIMessage(role: .assistant, content: "Do any of your children have kids (your grandchildren)?"),
            AIMessage(role: .user, content: "Andrew's kids are Teddy and Max")
        ]
        let response = try await provider.chat(messages: messages)
        let people = extractAllPeople(from: response)

        XCTAssertGreaterThanOrEqual(people.count, 2, "Should extract 2 grandchildren")
        let teddy = people.first { $0.firstName == "Teddy" }
        XCTAssertNotNil(teddy)
        // Teddy should be a child of Andrew
        let childRel = teddy?.relationships.first { $0.type == "child" && $0.personName == "Andrew" }
        XCTAssertNotNil(childRel, "Teddy should be linked as child of Andrew")
    }

    /// Verify names are properly capitalized.
    func testNameCapitalization() async throws {
        let provider = LocalInterviewProvider()

        let messages = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: "john smith")
        ]
        let response = try await provider.chat(messages: messages)
        let person = extractPerson(from: response)

        XCTAssertEqual(person?.firstName, "John", "Names should be capitalized")
        XCTAssertEqual(person?.lastName, "Smith", "Last names should be capitalized")
    }

    /// Verify garbage input is not parsed as names.
    func testGarbageInputRejected() async throws {
        let provider = LocalInterviewProvider()

        let messages = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: "John Smith"),
            AIMessage(role: .assistant, content: "Parents?"),
            AIMessage(role: .user, content: "Don't know their names")
        ]
        let response = try await provider.chat(messages: messages)
        let people = extractAllPeople(from: response)

        // "Don't" and "know" should NOT become person names
        let garbage = people.filter { $0.firstName.lowercased().hasPrefix("don") || $0.firstName.lowercased() == "know" }
        XCTAssertEqual(garbage.count, 0, "Should not create people from conversational phrases")
    }

    // MARK: - Helpers

    private func extractPerson(from text: String) -> ExtractedPerson? {
        extractAllPeople(from: text).first
    }

    private func extractAllPeople(from text: String) -> [ExtractedPerson] {
        let pattern = #"```json[^\n]*\n([\s\S]*?)\n\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            guard let data = String(text[range]).data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ExtractedPerson.self, from: data)
        }
    }
}
