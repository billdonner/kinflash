import Foundation
import FoundationModels

/// Apple Intelligence provider using on-device FoundationModels (iOS 26+).
/// Throws on failure — no silent fallback. The UI handles retry.
struct AppleIntelligenceProvider: AIProvider {

    var isAvailable: Bool {
        #if targetEnvironment(macCatalyst) && DEBUG
        return false
        #else
        return SystemLanguageModel.default.isAvailable
        #endif
    }

    func chat(messages: [AIMessage]) async throws -> String {
        guard isAvailable else {
            throw AIProviderError.notAvailable
        }
        let (instructions, userPrompt) = buildPrompt(from: messages)
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: userPrompt)
        return response.content
    }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        guard isAvailable else {
            return AsyncThrowingStream { $0.finish(throwing: AIProviderError.notAvailable) }
        }

        return AsyncThrowingStream { continuation in
            // Launch the AI work in a task we can cancel
            let workTask = Task {
                let (instructions, userPrompt) = buildPrompt(from: messages)
                let session = LanguageModelSession(instructions: instructions)
                var lastLength = 0
                let stream = session.streamResponse(to: userPrompt)
                for try await partial in stream {
                    try Task.checkCancellation()
                    let current = partial.content
                    if current.count > lastLength {
                        let delta = String(current.dropFirst(lastLength))
                        continuation.yield(delta)
                        lastLength = current.count
                    }
                }
                continuation.finish()
            }

            // Launch a watchdog that cancels the work after 15 seconds of no output
            Task {
                try? await Task.sleep(for: .seconds(15))
                if !workTask.isCancelled {
                    workTask.cancel()
                    continuation.finish(throwing: AIProviderError.networkError(
                        NSError(domain: "AppleIntelligence", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence did not respond within 15 seconds. The on-device model may not be ready. Please try again."])
                    ))
                }
            }
        }
    }

    // MARK: - Prompt Building

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
