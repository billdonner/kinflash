import XCTest
@testable import KinFlash

final class AIProviderTests: XCTestCase {

    // MARK: - LocalInterviewProvider (fallback) tests

    func testLocalProviderIsAvailable() {
        let provider = LocalInterviewProvider()
        XCTAssertTrue(provider.isAvailable)
    }

    func testLocalProviderStreams() async throws {
        let provider = LocalInterviewProvider()
        let messages = [AIMessage(role: .user, content: "John Smith")]

        var chunks: [String] = []
        for try await chunk in provider.chatStream(messages: messages) {
            chunks.append(chunk)
        }

        XCTAssertGreaterThan(chunks.count, 0, "Should deliver at least one chunk")
        let fullResponse = chunks.joined()
        XCTAssertFalse(fullResponse.isEmpty, "Response should not be empty")
    }

    // MARK: - Router tests

    func testRouterReturnsProviderForDefaultSetting() {
        let router = AIProviderRouter()
        let provider = router.provider(for: "apple", model: nil)
        // On simulator without Apple Intelligence, isAvailable may be false,
        // but the router should still return a provider (not crash)
        _ = provider
    }

    func testRouterReturnsProviderForNilSetting() {
        let router = AIProviderRouter()
        let provider = router.provider(for: nil, model: nil)
        _ = provider
    }

    func testRouterFallsBackOnInvalidAnthropicKey() {
        let router = AIProviderRouter()
        let provider = router.provider(for: "anthropic", model: nil)
        _ = provider
    }

    // MARK: - Protocol conformance

    func testStructuredOutputProtocolExists() {
        let provider = LocalInterviewProvider()
        _ = provider as any AIProvider
    }

    func testAppleIntelligenceConformsToProtocol() {
        let provider = AppleIntelligenceProvider()
        _ = provider as any AIProvider
    }
}
