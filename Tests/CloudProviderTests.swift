import XCTest
import GRDB
@testable import KinFlash

/// Live tests against Anthropic and OpenAI APIs.
/// These require valid API keys in the Keychain.
/// Tests are skipped if keys are not present.
final class CloudProviderTests: XCTestCase {

    private let keychain = KeychainManager()

    private var anthropicKey: String? {
        keychain.get(key: "anthropic_api_key")
    }

    private var openAIKey: String? {
        keychain.get(key: "openai_api_key")
    }

    // MARK: - Anthropic Tests

    func testAnthropicResponds() async throws {
        try XCTSkipIf(anthropicKey == nil || anthropicKey!.isEmpty, "No Anthropic API key")
        let provider = AnthropicProvider(apiKey: anthropicKey!, model: "claude-sonnet-4-6")
        let response = try await provider.chat(messages: [
            AIMessage(role: .user, content: "Say hello in one word")
        ])
        XCTAssertFalse(response.isEmpty)
        print("[CloudTest] Anthropic response: \(response)")
    }

    func testAnthropicExtractsName() async throws {
        try XCTSkipIf(anthropicKey == nil || anthropicKey!.isEmpty, "No Anthropic API key")
        let db = try DatabaseManager(inMemory: true)
        let provider = AnthropicProvider(apiKey: anthropicKey!, model: "claude-sonnet-4-6")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "John Smith",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        print("[CloudTest] Anthropic name extraction: \(response.prefix(300))")

        let people = extractAll(from: response)
        XCTAssertGreaterThan(people.count, 0, "Anthropic should extract at least one person")
        let john = people.first { $0.firstName == "John" }
        XCTAssertNotNil(john, "Should extract John. Got: \(people.map(\.firstName))")
    }

    func testAnthropicExtractsMultiplePeople() async throws {
        try XCTSkipIf(anthropicKey == nil || anthropicKey!.isEmpty, "No Anthropic API key")
        let db = try DatabaseManager(inMemory: true)
        let provider = AnthropicProvider(apiKey: anthropicKey!, model: "claude-sonnet-4-6")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "My parents are Robert Green and Susan Green",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        print("[CloudTest] Anthropic multi-person: \(response.prefix(400))")

        let people = extractAll(from: response)
        XCTAssertGreaterThanOrEqual(people.count, 2, "Should extract both parents")
        XCTAssertTrue(people.contains { $0.firstName == "Robert" }, "Should extract Robert")
        XCTAssertTrue(people.contains { $0.firstName == "Susan" }, "Should extract Susan")
    }

    func testAnthropicRelatedToField() async throws {
        try XCTSkipIf(anthropicKey == nil || anthropicKey!.isEmpty, "No Anthropic API key")
        let db = try DatabaseManager(inMemory: true)
        let provider = AnthropicProvider(apiKey: anthropicKey!, model: "claude-sonnet-4-6")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "Andrew married Katherine, their kids are George and Teddy",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        print("[CloudTest] Anthropic relatedTo: \(response.prefix(500))")

        let people = extractAll(from: response)
        let katherine = people.first { $0.firstName == "Katherine" }
        let george = people.first { $0.firstName == "George" }

        if let k = katherine {
            print("[CloudTest] Katherine relatedTo: \(k.relatedTo ?? "nil")")
            XCTAssertEqual(k.relatedTo?.lowercased(), "andrew", "Katherine should be related to Andrew")
        }
        if let g = george {
            print("[CloudTest] George relatedTo: \(g.relatedTo ?? "nil")")
            XCTAssertEqual(g.relatedTo?.lowercased(), "andrew", "George should be related to Andrew")
        }
    }

    func testAnthropicDoesNotHallucinate() async throws {
        try XCTSkipIf(anthropicKey == nil || anthropicKey!.isEmpty, "No Anthropic API key")
        let db = try DatabaseManager(inMemory: true)
        let provider = AnthropicProvider(apiKey: anthropicKey!, model: "claude-sonnet-4-6")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "Alice Wonderland",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        let people = extractAll(from: response)
        XCTAssertLessThanOrEqual(people.count, 1, "Should not hallucinate extra people from one name")
    }

    // MARK: - OpenAI Tests

    func testOpenAIResponds() async throws {
        try XCTSkipIf(openAIKey == nil || openAIKey!.isEmpty, "No OpenAI API key")
        let provider = OpenAIProvider(apiKey: openAIKey!, model: "gpt-4o-mini")
        let response = try await provider.chat(messages: [
            AIMessage(role: .user, content: "Say hello in one word")
        ])
        XCTAssertFalse(response.isEmpty)
        print("[CloudTest] OpenAI response: \(response)")
    }

    func testOpenAIExtractsName() async throws {
        try XCTSkipIf(openAIKey == nil || openAIKey!.isEmpty, "No OpenAI API key")
        let db = try DatabaseManager(inMemory: true)
        let provider = OpenAIProvider(apiKey: openAIKey!, model: "gpt-4o-mini")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "Jane Doe",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        print("[CloudTest] OpenAI name extraction: \(response.prefix(300))")

        let people = extractAll(from: response)
        XCTAssertGreaterThan(people.count, 0, "OpenAI should extract at least one person")
        let jane = people.first { $0.firstName == "Jane" }
        XCTAssertNotNil(jane, "Should extract Jane. Got: \(people.map(\.firstName))")
    }

    func testOpenAIExtractsMultiplePeople() async throws {
        try XCTSkipIf(openAIKey == nil || openAIKey!.isEmpty, "No OpenAI API key")
        let db = try DatabaseManager(inMemory: true)
        let provider = OpenAIProvider(apiKey: openAIKey!, model: "gpt-4o-mini")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "My wife is Sara, my sons are Tom and Mike",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        print("[CloudTest] OpenAI multi-person: \(response.prefix(500))")

        let people = extractAll(from: response)
        XCTAssertGreaterThanOrEqual(people.count, 3, "Should extract Sara, Tom, Mike")
    }

    func testOpenAIRelatedToField() async throws {
        try XCTSkipIf(openAIKey == nil || openAIKey!.isEmpty, "No OpenAI API key")
        let db = try DatabaseManager(inMemory: true)
        let provider = OpenAIProvider(apiKey: openAIKey!, model: "gpt-4o-mini")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "David married Lisa, their daughter is Emma",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        print("[CloudTest] OpenAI relatedTo: \(response.prefix(500))")

        let people = extractAll(from: response)
        let emma = people.first { $0.firstName == "Emma" }
        if let e = emma {
            print("[CloudTest] Emma relatedTo: \(e.relatedTo ?? "nil")")
            XCTAssertEqual(e.relatedTo?.lowercased(), "david", "Emma should be related to David")
        }
    }

    func testOpenAIDoesNotHallucinate() async throws {
        try XCTSkipIf(openAIKey == nil || openAIKey!.isEmpty, "No OpenAI API key")
        let db = try DatabaseManager(inMemory: true)
        let provider = OpenAIProvider(apiKey: openAIKey!, model: "gpt-4o-mini")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "Poo Bah",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        let people = extractAll(from: response)
        XCTAssertLessThanOrEqual(people.count, 1, "Should not hallucinate extra people")
        if let p = people.first {
            XCTAssertEqual(p.firstName.lowercased(), "poo", "Should extract 'Poo' not substitute. Got: \(p.firstName)")
        }
    }

    // MARK: - Tree Context Tests (cloud providers with existing tree)

    func testAnthropicWithTreeContext() async throws {
        try XCTSkipIf(anthropicKey == nil || anthropicKey!.isEmpty, "No Anthropic API key")
        let db = try DatabaseManager(inMemory: true)
        let ts = TreeService(dbQueue: db.dbQueue)

        // Build a small tree
        let john = Person(id: UUID(), firstName: "John", middleName: nil, lastName: "Smith",
                          nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                          isLiving: true, birthPlace: nil, gender: .male, notes: nil,
                          profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
        try ts.addPerson(john)
        try { try db.dbQueue.write { database in
            var settings = try AppSettings.current(database)
            settings.rootPersonId = john.id
            try settings.update(database)
        } }()

        let provider = AnthropicProvider(apiKey: anthropicKey!, model: "claude-sonnet-4-6")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // The prompt should now include the tree context
        let prompt = service.testableSystemPrompt
        XCTAssertTrue(prompt.contains("John Smith"), "Cloud prompt should include existing tree member")

        let (response, _) = try await service.processMessage(
            userMessage: "John's wife is Mary Smith",
            conversationHistory: [AIMessage(role: .system, content: prompt)]
        )
        let people = extractAll(from: response)
        let mary = people.first { $0.firstName == "Mary" }
        XCTAssertNotNil(mary, "Should extract Mary")
        print("[CloudTest] Anthropic with tree context: \(people.map { "\($0.firstName) relatedTo:\($0.relatedTo ?? "nil")" })")
    }

    func testOpenAIWithTreeContext() async throws {
        try XCTSkipIf(openAIKey == nil || openAIKey!.isEmpty, "No OpenAI API key")
        let db = try DatabaseManager(inMemory: true)
        let ts = TreeService(dbQueue: db.dbQueue)

        let jane = Person(id: UUID(), firstName: "Jane", middleName: nil, lastName: "Doe",
                          nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                          isLiving: true, birthPlace: nil, gender: .female, notes: nil,
                          profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
        try ts.addPerson(jane)
        try { try db.dbQueue.write { database in
            var settings = try AppSettings.current(database)
            settings.rootPersonId = jane.id
            try settings.update(database)
        } }()

        let provider = OpenAIProvider(apiKey: openAIKey!, model: "gpt-4o-mini")
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let prompt = service.testableSystemPrompt
        XCTAssertTrue(prompt.contains("Jane Doe"), "Cloud prompt should include existing tree member")

        let (response, _) = try await service.processMessage(
            userMessage: "Jane's brother is Bob Doe",
            conversationHistory: [AIMessage(role: .system, content: prompt)]
        )
        let people = extractAll(from: response)
        let bob = people.first { $0.firstName == "Bob" }
        XCTAssertNotNil(bob, "Should extract Bob")
        print("[CloudTest] OpenAI with tree context: \(people.map { "\($0.firstName) relatedTo:\($0.relatedTo ?? "nil")" })")
    }

    // MARK: - Helpers

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
}
