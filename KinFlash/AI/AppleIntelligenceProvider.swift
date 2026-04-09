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

        let (instructions, userPrompt) = buildPrompt(from: messages)
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: userPrompt)
        return response.content
    }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        guard isAvailable else {
            return LocalInterviewProvider().chatStream(messages: messages)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (instructions, userPrompt) = buildPrompt(from: messages)
                    let session = LanguageModelSession(instructions: instructions)

                    var lastLength = 0
                    let stream = session.streamResponse(to: userPrompt)
                    for try await partial in stream {
                        // partial.content is the full response so far; yield the delta
                        let current = partial.content
                        if current.count > lastLength {
                            let delta = String(current.dropFirst(lastLength))
                            continuation.yield(delta)
                            lastLength = current.count
                        }
                    }
                    continuation.finish()
                } catch {
                    // If FoundationModels fails, fall back to local provider
                    do {
                        let fallback = try await LocalInterviewProvider().chat(messages: messages)
                        continuation.yield(fallback)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Prompt Building

    /// Separate system instructions from the conversation and build the final user prompt.
    /// FoundationModels uses `Instructions` (system) + a single user string per turn.
    /// We concatenate the conversation history into the user prompt so the model has context.
    private func buildPrompt(from messages: [AIMessage]) -> (instructions: String, userPrompt: String) {
        var systemParts: [String] = []
        var conversationParts: [String] = []

        for msg in messages {
            switch msg.role {
            case .system:
                systemParts.append(msg.content)
            case .user:
                conversationParts.append("User: \(msg.content)")
            case .assistant:
                conversationParts.append("Assistant: \(msg.content)")
            }
        }

        let instructions = systemParts.joined(separator: "\n\n")
        let conversation = conversationParts.joined(separator: "\n\n")
        let userPrompt = conversation.isEmpty ? "Hello" : conversation + "\n\nAssistant:"

        return (instructions, userPrompt)
    }
}
