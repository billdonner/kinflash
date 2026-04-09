import Foundation

final class AIProviderRouter: Sendable {
    private let keychainManager: KeychainManager

    init(keychainManager: KeychainManager = KeychainManager()) {
        self.keychainManager = keychainManager
    }

    func provider(for selection: String?, model: String?) -> (any AIProvider)? {
        switch selection {
        case "anthropic":
            guard let key = keychainManager.get(key: "anthropic_api_key"), !key.isEmpty else {
                return nil
            }
            return AnthropicProvider(apiKey: key, model: model ?? "claude-sonnet-4-6")
        case "openai":
            guard let key = keychainManager.get(key: "openai_api_key"), !key.isEmpty else {
                return nil
            }
            return OpenAIProvider(apiKey: key, model: model ?? "gpt-4o")
        default:
            // Apple Intelligence would go here; for now return nil
            return nil
        }
    }
}
