import Foundation
import FoundationModels

/// Thread-safe flag for watchdog coordination
private final class AtomicFlag: @unchecked Sendable {
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { _value }
        set { _value = newValue }
    }
}

/// Apple Intelligence provider using on-device FoundationModels (iOS 26+).
struct AppleIntelligenceProvider: AIProvider {

    var isAvailable: Bool {
        #if targetEnvironment(macCatalyst) && DEBUG
        print("[AI] AppleIntelligence: disabled on Mac Catalyst debug builds")
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
        print("[AI] AppleIntelligence.chat: sending \(userPrompt.count) chars")
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: userPrompt)
        print("[AI] AppleIntelligence.chat: got \(response.content.count) chars")
        print("[AI] AppleIntelligence.chat RAW: \(response.content)")
        return response.content
    }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        guard isAvailable else {
            return AsyncThrowingStream { $0.finish(throwing: AIProviderError.notAvailable) }
        }

        let (instructions, userPrompt) = buildPrompt(from: messages)
        print("[AI] AppleIntelligence.stream: starting with \(userPrompt.count) chars, \(messages.count) messages")

        return AsyncThrowingStream { continuation in
            let finished = AtomicFlag(false)

            let workTask = Task { @Sendable in
                defer { finished.value = true }
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

            // Watchdog: cancel only if work hasn't finished
            Task { @Sendable in
                try? await Task.sleep(for: .seconds(15))
                if !workTask.isCancelled && !finished.value {
                    print("[AI] AppleIntelligence.stream: WATCHDOG FIRED — no response in 15 seconds")
                    workTask.cancel()
                    continuation.finish(throwing: AIProviderError.networkError(
                        NSError(domain: "AppleIntelligence", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence did not respond within 15 seconds. Please try again."])
                    ))
                }
            }
        }
    }

    // MARK: - Prompt Building

    /// Build prompt with context trimming.
    /// On-device models have small context windows (~4K tokens).
    /// Keep system prompt + last 6 conversation turns (3 user + 3 assistant).
    private func buildPrompt(from messages: [AIMessage]) -> (instructions: String, userPrompt: String) {
        var systemParts: [String] = []
        var nonSystemMessages: [AIMessage] = []

        for msg in messages {
            if msg.role == .system {
                systemParts.append(msg.content)
            } else {
                nonSystemMessages.append(msg)
            }
        }

        // Keep only the last 6 non-system messages to stay within context window
        let maxTurns = 6
        let trimmed = nonSystemMessages.suffix(maxTurns)
        if nonSystemMessages.count > maxTurns {
            print("[AI] Context trimmed: \(nonSystemMessages.count) → \(trimmed.count) messages")
        }

        // Build the user prompt as just the last user message.
        // Include brief conversation summary for context, but don't
        // use "User:"/"Assistant:" prefixes — the model echoes them.
        let lastUserMsg = trimmed.last { $0.role == .user }?.content ?? "Hello"

        let instructions = systemParts.joined(separator: "\n\n")
        return (instructions, lastUserMsg)
    }
}
