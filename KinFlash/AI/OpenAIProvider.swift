import Foundation

struct OpenAIProvider: AIProvider {
    let apiKey: String
    let model: String
    private let endpoint = "https://api.openai.com/v1/chat/completions"
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let chatMessages = messages.map { msg in
            ["role": msg.role.rawValue, "content": msg.content]
        }

        let body: [String: Any] = [
            "model": model,
            "messages": chatMessages,
            "max_tokens": 4096
        ]

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
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIProviderError.invalidResponse
        }

        return text
    }
}
