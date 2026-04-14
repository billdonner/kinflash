import XCTest
import GRDB
@testable import KinFlash

/// SLOW TESTS — ~30-60 seconds per provider. Feeds 5 interview turns through
/// each live AI and verifies the tree structure. Skip with Cmd+U if you just
/// want fast feedback; run explicitly when testing AI integration.
final class LiveAIDialogTests: XCTestCase {

    private let keychain = KeychainManager()

    private let turns = [
        "John Smith",
        "My wife is Mary Jones",
        "My parents are Robert Smith and Helen Brown",
        "My children are Michael, Sarah, and Emily Smith",
        "My brother is David Smith",
    ]

    /// Run the dialog and return (people count, has spouse, has parents, has children)
    private func runDialog(provider: any AIProvider) async throws -> (Int, Bool, Bool, Bool) {
        let db = try DatabaseManager(inMemory: true)
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)
        var history: [AIMessage] = []

        for (i, turn) in turns.enumerated() {
            let (response, _) = try await service.processMessage(
                userMessage: turn, conversationHistory: history
            )
            // Build history
            history.append(AIMessage(role: .user, content: turn))
            history.append(AIMessage(role: .assistant, content: response))

            // Extract and save
            let people = extractAll(from: response)
            let selfFirst = people.sorted { ($0.role == "self" ? 0 : 1) < ($1.role == "self" ? 0 : 1) }
            for p in selfFirst where p.isPersonComplete {
                let saved = try service.saveExtractedPerson(p)
                if i == 0 {
                    try { try db.dbQueue.write { database in
                        var s = try AppSettings.current(database)
                        s.rootPersonId = saved.id
                        try s.update(database)
                    } }()
                }
            }
            print("[LiveAI] Turn \(i+1): extracted \(people.count) from '\(turn)'")
        }

        let allPeople: [Person] = try { try db.dbQueue.read { try Person.fetchAll($0) } }()
        let rels: [Relationship] = try { try db.dbQueue.read { try Relationship.fetchAll($0) } }()
        let hasSpouse = rels.contains { $0.type == .spouse }
        let hasParent = rels.contains { $0.type == .parent }
        let hasChild = rels.contains { r in
            r.type == .parent && allPeople.contains { $0.firstName == "Michael" && r.toPersonId == $0.id }
        }

        print("[LiveAI] Result: \(allPeople.count) people, \(rels.count) rels, spouse=\(hasSpouse), parent=\(hasParent)")
        print("[LiveAI] Names: \(allPeople.map(\.displayName).sorted())")
        return (allPeople.count, hasSpouse, hasParent, hasChild)
    }

    // MARK: - Anthropic

    func testAnthropicFullDialog() async throws {
        guard let key = keychain.get(key: "anthropic_api_key"), !key.isEmpty else {
            throw XCTSkip("No Anthropic API key — set in Settings app first")
        }
        let provider = AnthropicProvider(apiKey: key, model: "claude-sonnet-4-6")
        let (count, hasSpouse, hasParent, _) = try await runDialog(provider: provider)

        XCTAssertGreaterThanOrEqual(count, 5, "Anthropic should extract at least 5 people from 5 turns")
        XCTAssertTrue(hasSpouse, "Should have a spouse relationship")
        XCTAssertTrue(hasParent, "Should have parent relationships")
    }

    // MARK: - OpenAI

    func testOpenAIFullDialog() async throws {
        guard let key = keychain.get(key: "openai_api_key"), !key.isEmpty else {
            throw XCTSkip("No OpenAI API key — set in Settings app first")
        }
        let provider = OpenAIProvider(apiKey: key, model: "gpt-4o-mini")
        let (count, hasSpouse, hasParent, _) = try await runDialog(provider: provider)

        XCTAssertGreaterThanOrEqual(count, 5, "OpenAI should extract at least 5 people from 5 turns")
        XCTAssertTrue(hasSpouse, "Should have a spouse relationship")
        XCTAssertTrue(hasParent, "Should have parent relationships")
    }

    // MARK: - Apple Intelligence (device only)

    func testAppleIntelligenceFullDialog() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Apple Intelligence requires real device")
        #else
        let provider = AppleIntelligenceProvider()
        guard provider.isAvailable else {
            throw XCTSkip("Apple Intelligence not available on this device")
        }
        let (count, hasSpouse, hasParent, _) = try await runDialog(provider: provider)

        XCTAssertGreaterThanOrEqual(count, 3, "Apple Intelligence should extract at least 3 people")
        // Lower bar for on-device — it struggles with complex extractions
        #endif
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
            if let p = try? JSONDecoder().decode(ExtractedPerson.self, from: data) {
                results.append(p)
            } else if let ps = try? JSONDecoder().decode([ExtractedPerson].self, from: data) {
                results.append(contentsOf: ps)
            } else {
                for line in jsonStr.components(separatedBy: .newlines) {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("{"), let d = t.data(using: .utf8) else { continue }
                    if let p = try? JSONDecoder().decode(ExtractedPerson.self, from: d) { results.append(p) }
                }
            }
        }
        return results
    }
}
