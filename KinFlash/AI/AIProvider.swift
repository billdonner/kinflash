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
    func structured<T: Decodable & Sendable>(
        prompt: String,
        schema: AISchema,
        as type: T.Type
    ) async throws -> T
    var isAvailable: Bool { get }
}

// Default implementations
extension AIProvider {
    func chat(messages: [AIMessage]) async throws -> String {
        var result = ""
        for try await chunk in chatStream(messages: messages) {
            result += chunk
        }
        return result
    }

    /// Default structured output: use chat with JSON prompt, then decode.
    func structured<T: Decodable & Sendable>(
        prompt: String,
        schema: AISchema,
        as type: T.Type
    ) async throws -> T {
        let systemMessage = """
            You must respond with valid JSON matching this schema: \(schema.jsonSchema)
            Description: \(schema.description)
            Respond ONLY with the JSON object, no markdown, no explanation.
            """
        let messages = [
            AIMessage(role: .system, content: systemMessage),
            AIMessage(role: .user, content: prompt)
        ]
        let response = try await chat(messages: messages)

        // Strip any markdown code fences
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw AIProviderError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIProviderError.decodingError(error)
        }
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
