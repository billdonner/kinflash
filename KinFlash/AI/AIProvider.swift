import Foundation

enum AIRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

struct AIMessage: Sendable {
    let role: AIRole
    let content: String
}

struct AISchema: Sendable {
    let description: String
    let jsonSchema: String
}

protocol AIProvider: Sendable {
    func chat(messages: [AIMessage]) async throws -> String
    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error>
    var isAvailable: Bool { get }
}

// Default streaming implementation that collects the full response
extension AIProvider {
    func chat(messages: [AIMessage]) async throws -> String {
        var result = ""
        for try await chunk in chatStream(messages: messages) {
            result += chunk
        }
        return result
    }
}

enum AIProviderError: Error, LocalizedError {
    case notAvailable
    case invalidAPIKey
    case rateLimited
    case networkError(Error)
    case invalidResponse
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notAvailable: "AI provider is not available"
        case .invalidAPIKey: "Invalid API key"
        case .rateLimited: "Rate limited — please try again later"
        case .networkError(let e): "Network error: \(e.localizedDescription)"
        case .invalidResponse: "Invalid response from AI provider"
        case .decodingError(let e): "Failed to decode response: \(e.localizedDescription)"
        }
    }
}
