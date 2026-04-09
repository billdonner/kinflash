import XCTest
import GRDB
@testable import KinFlash

final class NicknameAndAgeTests: XCTestCase {

    func testNicknameInQuotesExtracted() async throws {
        let provider = LocalInterviewProvider()
        let messages = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: #"Bill "Poobah" Donner"#)
        ]
        let response = try await provider.chat(messages: messages)
        let people = extractAllPeople(from: response)
        let bill = people.first { $0.firstName == "Bill" }

        XCTAssertNotNil(bill)
        XCTAssertEqual(bill?.lastName, "Donner")
        XCTAssertEqual(bill?.nickname, "Poobah")
    }

    func testAgeConvertedToBirthYear() async throws {
        let provider = LocalInterviewProvider()
        let currentYear = Calendar.current.component(.year, from: Date())
        let messages = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: "Jane Doe"),
            AIMessage(role: .assistant, content: "Parents?"),
            AIMessage(role: .user, content: "no"),
            AIMessage(role: .assistant, content: "Spouse?"),
            AIMessage(role: .user, content: "no"),
            AIMessage(role: .assistant, content: "Do you have any children?"),
            AIMessage(role: .user, content: "Tom Doe, 25 and Sarah Doe, 22")
        ]
        let response = try await provider.chat(messages: messages)
        let people = extractAllPeople(from: response)

        let tom = people.first { $0.firstName == "Tom" }
        XCTAssertNotNil(tom)
        XCTAssertEqual(tom?.birthYear, currentYear - 25)

        let sarah = people.first { $0.firstName == "Sarah" }
        XCTAssertNotNil(sarah)
        XCTAssertEqual(sarah?.birthYear, currentYear - 22)
    }

    func testNicknameAndAgeTogether() async throws {
        let provider = LocalInterviewProvider()
        let currentYear = Calendar.current.component(.year, from: Date())
        let messages = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: #"Richard "Dick" Donner, 95"#)
        ]
        let response = try await provider.chat(messages: messages)
        let people = extractAllPeople(from: response)
        let richard = people.first { $0.firstName == "Richard" }

        XCTAssertNotNil(richard)
        XCTAssertEqual(richard?.lastName, "Donner")
        XCTAssertEqual(richard?.nickname, "Dick")
        XCTAssertEqual(richard?.birthYear, currentYear - 95)
    }

    func testDonePhraseStopsExtraction() async throws {
        let provider = LocalInterviewProvider()
        let messages = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: "John Smith"),
            AIMessage(role: .assistant, content: "Spouse?"),
            AIMessage(role: .user, content: "that's all")
        ]
        let response = try await provider.chat(messages: messages)
        let people = extractAllPeople(from: response)

        XCTAssertEqual(people.count, 0, "Done phrase should not extract any people")
        XCTAssertTrue(response.lowercased().contains("great") || response.lowercased().contains("looking"),
                       "Should give a wrap-up message")
    }

    func testDoneVariations() async throws {
        let provider = LocalInterviewProvider()

        for phrase in ["done", "I'm done", "that's it", "finished", "no more", "nothing else"] {
            let messages = [
                AIMessage(role: .system, content: ""),
                AIMessage(role: .user, content: "John"),
                AIMessage(role: .assistant, content: "Extended family?"),
                AIMessage(role: .user, content: phrase)
            ]
            let response = try await provider.chat(messages: messages)
            let people = extractAllPeople(from: response)
            XCTAssertEqual(people.count, 0, "'\(phrase)' should not extract people")
        }
    }

    func testMultipleChildrenWithAges() async throws {
        let provider = LocalInterviewProvider()
        let messages = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: "John Smith"),
            AIMessage(role: .assistant, content: "Parents?"),
            AIMessage(role: .user, content: "no"),
            AIMessage(role: .assistant, content: "Spouse?"),
            AIMessage(role: .user, content: "no"),
            AIMessage(role: .assistant, content: "Do you have any children?"),
            AIMessage(role: .user, content: "Andrew 45, Charlie 40, James 38")
        ]
        let response = try await provider.chat(messages: messages)
        let people = extractAllPeople(from: response)

        XCTAssertEqual(people.count, 3)
        XCTAssertTrue(people.contains { $0.firstName == "Andrew" })
        XCTAssertTrue(people.contains { $0.firstName == "Charlie" })
        XCTAssertTrue(people.contains { $0.firstName == "James" })
        // All should have birth years derived from ages
        XCTAssertTrue(people.allSatisfy { $0.birthYear != nil })
    }

    func testCantRememberRejected() async throws {
        let provider = LocalInterviewProvider()
        let messages = [
            AIMessage(role: .system, content: ""),
            AIMessage(role: .user, content: "John"),
            AIMessage(role: .assistant, content: "Parents?"),
            AIMessage(role: .user, content: "I can't remember their names")
        ]
        let response = try await provider.chat(messages: messages)
        let people = extractAllPeople(from: response)
        XCTAssertEqual(people.count, 0, "Should not create people from 'can't remember'")
    }

    // MARK: - Helpers

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
