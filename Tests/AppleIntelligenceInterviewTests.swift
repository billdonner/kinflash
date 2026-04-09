import XCTest
import GRDB
@testable import KinFlash

final class AppleIntelligenceInterviewTests: XCTestCase {

    /// Verify that AppleIntelligenceProvider emits parseable JSON blocks
    /// during a simulated interview flow so the default path actually creates people.
    func testDefaultProviderEmitsExtractableJSON() async throws {
        let provider = AppleIntelligenceProvider()

        // Simulate turn 1: user gives name
        let msg1 = [
            AIMessage(role: .system, content: "You are a family tree assistant."),
            AIMessage(role: .user, content: "John Smith")
        ]
        let r1 = try await provider.chat(messages: msg1)
        // Turn 1 asks for birth year — no JSON yet expected
        XCTAssertFalse(r1.isEmpty)

        // Simulate turn 2: user gives birth year — should emit JSON
        let msg2 = msg1 + [
            AIMessage(role: .assistant, content: r1),
            AIMessage(role: .user, content: "1985")
        ]
        let r2 = try await provider.chat(messages: msg2)
        let person = extractPerson(from: r2)
        XCTAssertNotNil(person, "Turn 2 should emit a JSON block with the root person")
        XCTAssertEqual(person?.firstName, "John")
        XCTAssertEqual(person?.lastName, "Smith")
        XCTAssertEqual(person?.birthYear, 1985)
        XCTAssertEqual(person?.isComplete, true)
    }

    func testDefaultProviderEmitsParentRelationships() async throws {
        let provider = AppleIntelligenceProvider()

        // Build up the conversation to turn 3 (parents)
        let msg = [
            AIMessage(role: .system, content: "You are a family tree assistant."),
            AIMessage(role: .user, content: "John Smith"),
            AIMessage(role: .assistant, content: "Great! When were you born?"),
            AIMessage(role: .user, content: "1985"),
            AIMessage(role: .assistant, content: "Got it! Now tell me about your parents."),
            AIMessage(role: .user, content: "Robert Smith and Helen Smith")
        ]
        let response = try await provider.chat(messages: msg)
        let people = extractAllPeople(from: response)
        XCTAssertGreaterThanOrEqual(people.count, 1, "Should emit at least one parent")

        // At least one should have a "parent" relationship to "John"
        let withParentRel = people.filter { person in
            person.relationships.contains { $0.type == "parent" }
        }
        XCTAssertGreaterThanOrEqual(withParentRel.count, 1, "At least one extracted person should have a parent relationship")
    }

    func testDefaultProviderEndToEndCreatesTreeViaInterviewService() async throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = AppleIntelligenceProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // Turn 1: name
        let (_, _) = try await service.processMessage(
            userMessage: "Jane Doe",
            conversationHistory: []
        )

        // Turn 2: birth year — should create person
        let history1 = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: "Jane Doe"),
            AIMessage(role: .assistant, content: "Great! When were you born?"),
        ]
        let (r2, extracted) = try await service.processMessage(
            userMessage: "1990",
            conversationHistory: history1
        )
        XCTAssertNotNil(extracted, "Should extract person on turn 2")
        if let person = extracted, person.isComplete {
            let saved = try service.saveExtractedPerson(person)
            XCTAssertEqual(saved.firstName, "Jane")
        }

        // Verify person exists in DB
        let people: [Person] = try {
            try db.dbQueue.read { database in
                try Person.fetchAll(database)
            }
        }()
        XCTAssertGreaterThanOrEqual(people.count, 1)
        XCTAssertTrue(people.contains { $0.firstName == "Jane" })
    }

    // MARK: - Helpers

    private func extractPerson(from text: String) -> ExtractedPerson? {
        let pattern = #"```json\s*([\s\S]*?)\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let json = String(text[range])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExtractedPerson.self, from: data)
    }

    private func extractAllPeople(from text: String) -> [ExtractedPerson] {
        let pattern = #"```json\s*([\s\S]*?)\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            guard let data = String(text[range]).data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ExtractedPerson.self, from: data)
        }
    }
}
