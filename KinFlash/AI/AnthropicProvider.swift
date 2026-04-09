import Foundation

struct AnthropicProvider: AIProvider {
    let apiKey: String
    let model: String
    private let endpoint = "https://api.anthropic.com/v1/messages"
    private let maxRetries = 3

    var isAvailable: Bool { !apiKey.isEmpty }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await performRequest(messages: messages)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func performRequest(messages: [AIMessage], attempt: Int = 0) async throws -> String {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemMessage = messages.first { $0.role == .system }?.content
        let chatMessages = messages.filter { $0.role != .system }.map { msg in
            ["role": msg.role.rawValue, "content": msg.content]
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": chatMessages
        ]
        if let system = systemMessage {
            body["system"] = system
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200: break
            case 401: throw AIProviderError.invalidAPIKey
            case 429:
                if attempt < maxRetries {
                    let delay = pow(2.0, Double(attempt))
                    try await Task.sleep(for: .seconds(delay))
                    return try await performRequest(messages: messages, attempt: attempt + 1)
                }
                throw AIProviderError.rateLimited
            default:
                if httpResponse.statusCode >= 500 && attempt < maxRetries {
                    let delay = pow(2.0, Double(attempt))
                    try await Task.sleep(for: .seconds(delay))
                    return try await performRequest(messages: messages, attempt: attempt + 1)
                }
                throw AIProviderError.invalidResponse
            }
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw AIProviderError.invalidResponse
        }

        return text
    }
}
