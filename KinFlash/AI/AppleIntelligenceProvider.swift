import Foundation
import FoundationModels

/// Apple Intelligence provider using on-device FoundationModels (iOS 26+).
/// Falls back to LocalInterviewProvider if the device doesn't support it.
struct AppleIntelligenceProvider: AIProvider {

    var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    func chat(messages: [AIMessage]) async throws -> String {
        guard isAvailable else {
            return try await LocalInterviewProvider().chat(messages: messages)
        }

        let session = LanguageModelSession()

        // Build the prompt from messages
        var prompt = ""
        for msg in messages {
            switch msg.role {
            case .system:
                prompt += "System: \(msg.content)\n\n"
            case .user:
                prompt += "User: \(msg.content)\n\n"
            case .assistant:
                prompt += "Assistant: \(msg.content)\n\n"
            }
        }
        prompt += "Assistant:"

        let response = try await session.respond(to: prompt)
        return response.content
    }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        guard isAvailable else {
            return LocalInterviewProvider().chatStream(messages: messages)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let session = LanguageModelSession()

                    var prompt = ""
                    for msg in messages {
                        switch msg.role {
                        case .system:
                            prompt += "System: \(msg.content)\n\n"
                        case .user:
                            prompt += "User: \(msg.content)\n\n"
                        case .assistant:
                            prompt += "Assistant: \(msg.content)\n\n"
                        }
                    }
                    prompt += "Assistant:"

                    let stream = session.streamResponse(to: prompt)
                    for try await partial in stream {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
