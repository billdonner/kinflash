import Foundation

final class AIProviderRouter: Sendable {
    private let keychainManager: KeychainManager

    init(keychainManager: KeychainManager = KeychainManager()) {
        self.keychainManager = keychainManager
    }

    /// Returns the appropriate AI provider based on user settings.
    /// Falls back to AppleIntelligenceProvider when no cloud provider is configured.
    func provider(for selection: String?, model: String?) -> any AIProvider {
        switch selection {
        case "anthropic":
            if let key = keychainManager.get(key: "anthropic_api_key"), !key.isEmpty {
                return AnthropicProvider(apiKey: key, model: model ?? "claude-sonnet-4-6")
            }
            // Invalid key — fall through to default
            return AppleIntelligenceProvider()

        case "openai":
            if let key = keychainManager.get(key: "openai_api_key"), !key.isEmpty {
                return OpenAIProvider(apiKey: key, model: model ?? "gpt-4o")
            }
            return AppleIntelligenceProvider()

        default:
            // "apple" or nil — use on-device AI
            return AppleIntelligenceProvider()
        }
    }
}
