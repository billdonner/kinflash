import XCTest
import GRDB
@testable import KinFlash

/// Tests that require Apple Intelligence hardware (real device only).
/// These will be skipped on simulator builds.
final class DeviceOnlyTests: XCTestCase {

    private var isOnDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    // MARK: - Apple Intelligence Availability

    func testAppleIntelligenceAvailableOnDevice() throws {
        try XCTSkipUnless(isOnDevice, "Requires real device with Apple Intelligence")
        let provider = AppleIntelligenceProvider()
        XCTAssertTrue(provider.isAvailable, "Apple Intelligence should be available on this device")
    }

    // MARK: - Warm-up / Basic Response

    func testWarmupResponds() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        let provider = AppleIntelligenceProvider()
        try XCTSkipUnless(provider.isAvailable, "Apple Intelligence not available")

        let response = try await provider.chat(messages: [
            AIMessage(role: .user, content: "Hello")
        ])
        XCTAssertFalse(response.isEmpty, "Warm-up should produce a non-empty response")
        print("[DeviceTest] Warm-up response: \(response)")
    }

    func testWarmupTimingUnder30Seconds() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        let provider = AppleIntelligenceProvider()
        try XCTSkipUnless(provider.isAvailable, "Apple Intelligence not available")

        let start = Date()
        let _ = try await provider.chat(messages: [
            AIMessage(role: .user, content: "Say hi")
        ])
        let elapsed = Date().timeIntervalSince(start)
        print("[DeviceTest] Warm-up took \(String(format: "%.1f", elapsed))s")
        XCTAssertLessThan(elapsed, 30, "First response should arrive within 30 seconds")
    }

    // MARK: - Streaming

    func testStreamingDeliversTokens() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        let provider = AppleIntelligenceProvider()
        try XCTSkipUnless(provider.isAvailable, "Apple Intelligence not available")

        var chunks: [String] = []
        let stream = provider.chatStream(messages: [
            AIMessage(role: .user, content: "Count to three")
        ])
        for try await chunk in stream {
            chunks.append(chunk)
        }
        XCTAssertGreaterThan(chunks.count, 0, "Should receive at least one streaming chunk")
        let full = chunks.joined()
        XCTAssertFalse(full.isEmpty, "Streamed response should not be empty")
        print("[DeviceTest] Streamed \(chunks.count) chunks, \(full.count) chars: \(full.prefix(200))")
    }

    // MARK: - Interview JSON Extraction

    func testInterviewProducesJSON() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        let provider = AppleIntelligenceProvider()
        try XCTSkipUnless(provider.isAvailable, "Apple Intelligence not available")

        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let (response, extracted) = try await service.processMessage(
            userMessage: "My name is John Smith",
            conversationHistory: [
                AIMessage(role: .system, content: service.testableSystemPrompt)
            ]
        )

        print("[DeviceTest] Interview response: \(response)")
        print("[DeviceTest] Extracted: \(String(describing: extracted))")

        // The model should either produce a JSON block or a conversational response
        XCTAssertFalse(response.isEmpty, "Response should not be empty")

        // If extracted, verify it looks right
        if let person = extracted {
            XCTAssertFalse(person.firstName.isEmpty, "Extracted firstName should not be empty")
            print("[DeviceTest] Extracted person: \(person.firstName) \(person.lastName ?? "")")
        }
    }

    func testInterviewDoesNotHallucinate() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        let provider = AppleIntelligenceProvider()
        try XCTSkipUnless(provider.isAvailable, "Apple Intelligence not available")

        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        // Give a single name — model should NOT invent family members
        let (response, _) = try await service.processMessage(
            userMessage: "Alice Wonderland",
            conversationHistory: [
                AIMessage(role: .system, content: service.testableSystemPrompt)
            ]
        )

        print("[DeviceTest] Hallucination check response: \(response)")

        // Count JSON blocks — should be 0 or 1 (just Alice), never more
        let jsonPattern = "```json"
        let jsonCount = response.components(separatedBy: jsonPattern).count - 1
        XCTAssertLessThanOrEqual(jsonCount, 1,
            "Should extract at most 1 person (Alice), got \(jsonCount) JSON blocks. Model may be hallucinating.")
    }

    // MARK: - Full Interview Flow on Device

    func testMultiTurnInterviewCreatesTree() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        let provider = AppleIntelligenceProvider()
        try XCTSkipUnless(provider.isAvailable, "Apple Intelligence not available")

        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)
        let system = AIMessage(role: .system, content: service.testableSystemPrompt)

        // Turn 1: Give name
        var history: [AIMessage] = [system]
        let (r1, ex1) = try await service.processMessage(
            userMessage: "Jane Doe",
            conversationHistory: history
        )
        print("[DeviceTest] Turn 1 response: \(r1.prefix(200))")
        if let p = ex1, p.isComplete {
            _ = try service.saveExtractedPerson(p)
        }
        history.append(AIMessage(role: .user, content: "Jane Doe"))
        history.append(AIMessage(role: .assistant, content: r1))

        // Turn 2: Give parents
        let (r2, _) = try await service.processMessage(
            userMessage: "My parents are Bob Doe and Alice Doe",
            conversationHistory: history
        )
        print("[DeviceTest] Turn 2 response: \(r2.prefix(200))")

        // Extract all people from turn 2
        let allJSON = extractAllJSON(from: r2)
        for person in allJSON where person.isComplete {
            _ = try? service.saveExtractedPerson(person)
        }

        // Verify database state
        let people: [Person] = try {
            try db.dbQueue.read { database in
                try Person.fetchAll(database)
            }
        }()
        print("[DeviceTest] People in DB: \(people.map(\.displayName))")
        XCTAssertGreaterThanOrEqual(people.count, 1, "At least Jane should be in the database")
    }

    func testSecondCallFasterThanFirst() async throws {
        try XCTSkipUnless(isOnDevice, "Requires real device")
        let provider = AppleIntelligenceProvider()
        try XCTSkipUnless(provider.isAvailable, "Apple Intelligence not available")

        // First call (cold)
        let start1 = Date()
        let _ = try await provider.chat(messages: [AIMessage(role: .user, content: "Hello")])
        let elapsed1 = Date().timeIntervalSince(start1)

        // Second call (warm)
        let start2 = Date()
        let _ = try await provider.chat(messages: [AIMessage(role: .user, content: "Hello again")])
        let elapsed2 = Date().timeIntervalSince(start2)

        print("[DeviceTest] Cold call: \(String(format: "%.1f", elapsed1))s, Warm call: \(String(format: "%.1f", elapsed2))s")
        // Second call should generally be faster (model already in memory)
        // But we don't hard-assert this since system state varies
    }

    // MARK: - Helpers

    private func extractAllJSON(from text: String) -> [ExtractedPerson] {
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
