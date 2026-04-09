import Foundation

final class AIProviderRouter: Sendable {
    private let keychainManager: KeychainManager

    init(keychainManager: KeychainManager = KeychainManager()) {
        self.keychainManager = keychainManager
    }

    func provider(for selection: String?, model: String?) -> any AIProvider {
        let result: any AIProvider

        switch selection {
        case "anthropic":
            if let key = keychainManager.get(key: "anthropic_api_key"), !key.isEmpty {
                print("[AI] Router: selected Anthropic provider, model=\(model ?? "default")")
                result = AnthropicProvider(apiKey: key, model: model ?? "claude-sonnet-4-6")
            } else {
                print("[AI] Router: Anthropic selected but no API key, using default")
                result = defaultProvider()
            }

        case "openai":
            if let key = keychainManager.get(key: "openai_api_key"), !key.isEmpty {
                print("[AI] Router: selected OpenAI provider, model=\(model ?? "default")")
                result = OpenAIProvider(apiKey: key, model: model ?? "gpt-4o")
            } else {
                print("[AI] Router: OpenAI selected but no API key, using default")
                result = defaultProvider()
            }

        default:
            print("[AI] Router: selection=\(selection ?? "nil"), using default provider")
            result = defaultProvider()
        }

        print("[AI] Router: provider=\(type(of: result)), isAvailable=\(result.isAvailable)")
        return result
    }

    private func defaultProvider() -> any AIProvider {
        #if targetEnvironment(macCatalyst) && DEBUG
        print("[AI] Router: Mac Catalyst debug → LocalInterviewProvider")
        return LocalInterviewProvider()
        #else
        print("[AI] Router: using AppleIntelligenceProvider")
        return AppleIntelligenceProvider()
        #endif
    }
}
