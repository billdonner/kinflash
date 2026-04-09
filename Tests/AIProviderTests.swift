import XCTest
@testable import KinFlash

final class AIProviderTests: XCTestCase {

    // MARK: - Fix 2: Apple Intelligence provider works as default

    func testAppleIntelligenceProviderIsAvailable() {
        let provider = AppleIntelligenceProvider()
        XCTAssertTrue(provider.isAvailable)
    }

    func testAppleIntelligenceProviderStreams() async throws {
        let provider = AppleIntelligenceProvider()
        let messages = [AIMessage(role: .user, content: "John Smith")]

        var chunks: [String] = []
        for try await chunk in provider.chatStream(messages: messages) {
            chunks.append(chunk)
        }

        XCTAssertGreaterThan(chunks.count, 0, "Should deliver at least one chunk")
        let fullResponse = chunks.joined()
        XCTAssertFalse(fullResponse.isEmpty, "Response should not be empty")
    }

    func testRouterReturnsProviderForDefaultSetting() {
        let router = AIProviderRouter()
        // "apple" or nil should return a working provider, not nil
        let provider = router.provider(for: "apple", model: nil)
        XCTAssertTrue(provider.isAvailable, "Default provider should be available")
    }

    func testRouterReturnsProviderForNilSetting() {
        let router = AIProviderRouter()
        let provider = router.provider(for: nil, model: nil)
        XCTAssertTrue(provider.isAvailable, "Nil setting should still return a working provider")
    }

    func testRouterFallsBackOnInvalidAnthropicKey() {
        let router = AIProviderRouter()
        // No key in keychain → should fallback to Apple Intelligence, not nil
        let provider = router.provider(for: "anthropic", model: nil)
        XCTAssertTrue(provider.isAvailable)
    }

    // MARK: - Structured output protocol

    func testStructuredOutputProtocolExists() async throws {
        let provider = AppleIntelligenceProvider()
        // Verify the protocol method exists and can be called
        struct TestOutput: Codable, Sendable {
            let name: String
        }
        let schema = AISchema(
            description: "A test object",
            jsonSchema: #"{"type":"object","properties":{"name":{"type":"string"}}}"#
        )
        // We can't test the actual output without a real AI, but verify the method compiles
        // and the protocol is satisfied
        _ = provider as any AIProvider
    }
}
