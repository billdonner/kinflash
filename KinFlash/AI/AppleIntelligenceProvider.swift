import Foundation
import FoundationModels

/// Apple Intelligence provider using on-device FoundationModels (iOS 26+).
/// Throws on failure — no silent fallback. The UI handles retry.
struct AppleIntelligenceProvider: AIProvider {

    var isAvailable: Bool {
        #if targetEnvironment(macCatalyst) && DEBUG
        print("[AI] AppleIntelligence: disabled on Mac Catalyst debug builds (sandbox blocks XPC)")
        return false
        #else
        let available = SystemLanguageModel.default.isAvailable
        print("[AI] AppleIntelligence: SystemLanguageModel.isAvailable = \(available)")
        return available
        #endif
    }

    func chat(messages: [AIMessage]) async throws -> String {
        guard isAvailable else {
            throw AIProviderError.notAvailable
        }
        let (instructions, userPrompt) = buildPrompt(from: messages)
        print("[AI] AppleIntelligence.chat: sending \(userPrompt.count) chars to LanguageModelSession")
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: userPrompt)
        print("[AI] AppleIntelligence.chat: got \(response.content.count) char response")
        return response.content
    }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        guard isAvailable else {
            return AsyncThrowingStream { $0.finish(throwing: AIProviderError.notAvailable) }
        }

        let (instructions, userPrompt) = buildPrompt(from: messages)
        print("[AI] AppleIntelligence.stream: starting with \(userPrompt.count) chars, \(messages.count) messages")

        return AsyncThrowingStream { continuation in
            let workTask = Task {
                print("[AI] AppleIntelligence.stream: creating LanguageModelSession...")
                let session = LanguageModelSession(instructions: instructions)
                print("[AI] AppleIntelligence.stream: calling streamResponse...")
                var lastLength = 0
                var tokenCount = 0
                let stream = session.streamResponse(to: userPrompt)
                print("[AI] AppleIntelligence.stream: entering for-await loop...")
                for try await partial in stream {
                    try Task.checkCancellation()
                    let current = partial.content
                    if current.count > lastLength {
                        let delta = String(current.dropFirst(lastLength))
                        continuation.yield(delta)
                        lastLength = current.count
                        tokenCount += 1
                        if tokenCount == 1 {
                            print("[AI] AppleIntelligence.stream: first token received!")
                        }
                    }
                }
                print("[AI] AppleIntelligence.stream: complete, \(tokenCount) tokens, \(lastLength) chars total")
                continuation.finish()
            }

            // Watchdog: cancel if no response within 15 seconds
            Task {
                try? await Task.sleep(for: .seconds(15))
                if !workTask.isCancelled {
                    print("[AI] AppleIntelligence.stream: WATCHDOG FIRED — no response in 15 seconds, cancelling")
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
