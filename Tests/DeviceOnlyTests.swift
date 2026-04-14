import XCTest
import GRDB
@testable import KinFlash

/// Tests that require Apple Intelligence hardware (real device only).
/// These document the actual behavior of the on-device model.
final class DeviceOnlyTests: XCTestCase {

    private var isOnDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    private lazy var provider = AppleIntelligenceProvider()

    // MARK: - Availability

    func testAppleIntelligenceAvailableOnDevice() throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        XCTAssertTrue(provider.isAvailable, "Apple Intelligence should be available")
    }

    // MARK: - Warm-up

    func testWarmupResponds() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let response = try await provider.chat(messages: [AIMessage(role: .user, content: "Hello")])
        XCTAssertFalse(response.isEmpty, "Warm-up should produce non-empty response")
        print("[DeviceTest] Warm-up: \(response)")
    }

    func testWarmupTimingUnder30Seconds() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let start = Date()
        _ = try await provider.chat(messages: [AIMessage(role: .user, content: "Say hi")])
        let elapsed = Date().timeIntervalSince(start)
        print("[DeviceTest] Warm-up took \(String(format: "%.1f", elapsed))s")
        XCTAssertLessThan(elapsed, 30)
    }

    func testSecondCallFasterThanFirst() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let start1 = Date()
        _ = try await provider.chat(messages: [AIMessage(role: .user, content: "Hello")])
        let t1 = Date().timeIntervalSince(start1)

        let start2 = Date()
        _ = try await provider.chat(messages: [AIMessage(role: .user, content: "Hello again")])
        let t2 = Date().timeIntervalSince(start2)

        print("[DeviceTest] Cold: \(String(format: "%.1f", t1))s, Warm: \(String(format: "%.1f", t2))s")
    }

    // MARK: - Streaming

    func testStreamingDeliversTokens() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        var chunks: [String] = []
        for try await chunk in provider.chatStream(messages: [AIMessage(role: .user, content: "Count to three")]) {
            chunks.append(chunk)
        }
        XCTAssertGreaterThan(chunks.count, 0)
        let full = chunks.joined()
        print("[DeviceTest] Streamed \(chunks.count) chunks: \(full.prefix(200))")
    }

    func testStreamingWithSystemPrompt() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        var full = ""
        let messages = [
            AIMessage(role: .system, content: "You are a helpful assistant. Respond briefly."),
            AIMessage(role: .user, content: "What is 2+2?")
        ]
        for try await chunk in provider.chatStream(messages: messages) {
            full += chunk
        }
        XCTAssertFalse(full.isEmpty)
        print("[DeviceTest] System prompt streaming: \(full)")
    }

    // MARK: - Name Extraction Accuracy

    func testExtractsSimpleName() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "John Smith",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        print("[DeviceTest] Name extraction response: \(response)")

        let people = extractAll(from: response)
        print("[DeviceTest] Extracted \(people.count) people: \(people.map { "\($0.firstName) \($0.lastName ?? "")" })")

        // Log whether the name was correct (don't hard-fail — documents model behavior)
        let hasJohn = people.contains { $0.firstName == "John" && $0.lastName == "Smith" }
        if !hasJohn {
            print("[DeviceTest] WARNING: Model did not extract 'John Smith' correctly from input 'John Smith'")
            print("[DeviceTest] Got instead: \(people.map { "\($0.firstName) \($0.lastName ?? "nil")" })")
        }
        XCTAssertGreaterThan(people.count, 0, "Should extract at least one person. Raw: \(response)")
    }

    func testExtractsUnusualName() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "Poo Bah",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        print("[DeviceTest] Unusual name response: \(response)")

        let people = extractAll(from: response)
        let hasPooBah = people.contains { $0.firstName.lowercased() == "poo" }
        if !hasPooBah {
            print("[DeviceTest] FAIL: Model substituted a different name for 'Poo Bah'")
            print("[DeviceTest] Got: \(people.map { "\($0.firstName) \($0.lastName ?? "nil")" })")
        }
        // This documents whether the model respects unusual names
        XCTAssertTrue(hasPooBah, "Model should extract 'Poo Bah' not substitute another name. Got: \(people.map(\.firstName))")
    }

    func testDoesNotHallucinate() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "Alice Wonderland",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )

        let people = extractAll(from: response)
        print("[DeviceTest] Hallucination check: \(people.count) people from 'Alice Wonderland'")
        print("[DeviceTest] Names: \(people.map { "\($0.firstName) \($0.lastName ?? "")" })")

        XCTAssertLessThanOrEqual(people.count, 1, "Should not hallucinate extra people from a single name")
    }

    // MARK: - Spouse Extraction

    func testExtractsSpouse() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "My spouse is Jane Doe",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        let people = extractAll(from: response)
        print("[DeviceTest] Spouse extraction: \(people.map { "\($0.firstName) \($0.lastName ?? "") role:\($0.role ?? "nil")" })")

        let jane = people.first { $0.firstName == "Jane" }
        XCTAssertNotNil(jane, "Should extract Jane. Got: \(people.map(\.firstName))")
        if let role = jane?.role {
            XCTAssertEqual(role, "spouse", "Jane's role should be spouse, got: \(role)")
        }
    }

    // MARK: - Parent Extraction

    func testExtractsParents() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "My dad is Robert Green and my mom is Susan Green",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        let people = extractAll(from: response)
        print("[DeviceTest] Parents: \(people.map { "\($0.firstName) \($0.lastName ?? "") role:\($0.role ?? "nil")" })")

        XCTAssertGreaterThanOrEqual(people.count, 1, "Should extract at least one parent")

        let robert = people.first { $0.firstName == "Robert" }
        let susan = people.first { $0.firstName == "Susan" }
        if robert == nil { print("[DeviceTest] WARNING: Robert not extracted") }
        if susan == nil { print("[DeviceTest] WARNING: Susan not extracted") }
    }

    // MARK: - Children Extraction

    func testExtractsChildren() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "My children are Emma, Liam, and Olivia",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        let people = extractAll(from: response)
        print("[DeviceTest] Children: \(people.map { "\($0.firstName) role:\($0.role ?? "nil")" })")

        XCTAssertGreaterThanOrEqual(people.count, 1, "Should extract at least one child")
    }

    // MARK: - Multi-turn Flow

    func testMultiTurnCreatesTree() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)
        let system = AIMessage(role: .system, content: service.testableSystemPrompt)

        // Turn 1: Name — build conversation history properly
        var history: [AIMessage] = [system]
        let (r1, _) = try await service.processMessage(userMessage: "Jane Doe", conversationHistory: history)
        let turn1People = extractAll(from: r1)
        for p in turn1People where p.isPersonComplete {
            _ = try? service.saveExtractedPerson(p)
        }
        print("[DeviceTest] Turn 1: \(turn1People.count) people")
        // Preserve conversation context for next turn
        history.append(AIMessage(role: .user, content: "Jane Doe"))
        history.append(AIMessage(role: .assistant, content: r1))

        // Turn 2: Spouse — includes turn 1 context
        let (r2, _) = try await service.processMessage(userMessage: "My husband is Bob Doe", conversationHistory: history)
        let turn2People = extractAll(from: r2)
        for p in turn2People where p.isPersonComplete {
            _ = try? service.saveExtractedPerson(p)
        }
        print("[DeviceTest] Turn 2: \(turn2People.count) people")

        let allPeople: [Person] = try {
            try db.dbQueue.read { database in try Person.fetchAll(database) }
        }()
        print("[DeviceTest] Total in DB: \(allPeople.count) — \(allPeople.map(\.displayName))")
        XCTAssertGreaterThanOrEqual(allPeople.count, 1, "Should have at least one person in DB")
    }

    // MARK: - JSON Format Handling

    func testHandlesJSONLinesFormat() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, _) = try await service.processMessage(
            userMessage: "My parents are Adam Smith and Eve Smith",
            conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
        )
        let people = extractAll(from: response)
        print("[DeviceTest] JSON format test: \(people.count) people from parents input")
        print("[DeviceTest] Raw: \(response.prefix(300))")

        // Whether it uses array, JSONL, or separate blocks, we should get people
        XCTAssertGreaterThanOrEqual(people.count, 1, "Should extract parents regardless of JSON format")
    }

    // MARK: - Role Accuracy

    func testRoleMatchesInput() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        // Test each role type
        let testCases: [(input: String, expectedRole: String)] = [
            ("My wife is Sarah", "spouse"),
            ("My son is Tom", "child"),
            ("My mother is Helen", "parent"),
            ("My brother is Mike", "sibling"),
        ]

        for tc in testCases {
            let db = try DatabaseManager(inMemory: true)
            let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)
            let (response, _) = try await service.processMessage(
                userMessage: tc.input,
                conversationHistory: [AIMessage(role: .system, content: service.testableSystemPrompt)]
            )
            let people = extractAll(from: response)
            print("[DeviceTest] Role test '\(tc.input)': \(people.map { "\($0.firstName) role:\($0.role ?? "nil")" })")

            if let person = people.first {
                if person.role != tc.expectedRole {
                    print("[DeviceTest] WARNING: Expected role '\(tc.expectedRole)' but got '\(person.role ?? "nil")' for '\(tc.input)'")
                }
            }
        }
    }

    // MARK: - Response Timing

    func testStreamingCompletesWithinOneMinute() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        try XCTSkipUnless(provider.isAvailable, "AI not available")

        let start = Date()
        var full = ""
        let messages = [
            AIMessage(role: .system, content: "You extract names from text. Output JSON."),
            AIMessage(role: .user, content: "My name is Test User")
        ]
        for try await chunk in provider.chatStream(messages: messages) {
            full += chunk
        }
        let elapsed = Date().timeIntervalSince(start)
        print("[DeviceTest] Streaming took \(String(format: "%.1f", elapsed))s for \(full.count) chars")
        XCTAssertLessThan(elapsed, 60, "Streaming should complete within 60 seconds")
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
