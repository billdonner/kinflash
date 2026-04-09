import Foundation

final class AIProviderRouter: Sendable {
    private let keychainManager: KeychainManager

    init(keychainManager: KeychainManager = KeychainManager()) {
        self.keychainManager = keychainManager
    }

    func provider(for selection: String?, model: String?) -> any AIProvider {
        switch selection {
        case "anthropic":
            if let key = keychainManager.get(key: "anthropic_api_key"), !key.isEmpty {
                return AnthropicProvider(apiKey: key, model: model ?? "claude-sonnet-4-6")
            }
            return defaultProvider()

        case "openai":
            if let key = keychainManager.get(key: "openai_api_key"), !key.isEmpty {
                return OpenAIProvider(apiKey: key, model: model ?? "gpt-4o")
            }
            return defaultProvider()

        default:
            return defaultProvider()
        }
    }

    private func defaultProvider() -> any AIProvider {
        #if targetEnvironment(macCatalyst) && DEBUG
        // Mac Catalyst debug builds: sandbox blocks FoundationModels XPC
        return LocalInterviewProvider()
        #else
        return AppleIntelligenceProvider()
        #endif
    }
}
