import Foundation
import FoundationModels

/// Apple Intelligence provider using on-device FoundationModels (iOS 26+).
/// Falls back to LocalInterviewProvider if FoundationModels is unavailable
/// or fails (e.g., sandbox restrictions on Mac Catalyst).
struct AppleIntelligenceProvider: AIProvider {

    private let fallback = LocalInterviewProvider()

    var isAvailable: Bool {
        // Check both API availability and actual model readiness
        SystemLanguageModel.default.isAvailable
    }

    func chat(messages: [AIMessage]) async throws -> String {
        guard isAvailable else {
            return try await fallback.chat(messages: messages)
        }

        // Try Foundation Models with a timeout — falls back on any failure
        do {
            return try await withTimeout(seconds: 15) {
                let (instructions, userPrompt) = buildPrompt(from: messages)
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: userPrompt)
                return response.content
            }
        } catch {
            // Sandbox error, timeout, or any FoundationModels failure → use local
            return try await fallback.chat(messages: messages)
        }
    }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        guard isAvailable else {
            return fallback.chatStream(messages: messages)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (instructions, userPrompt) = buildPrompt(from: messages)
                    let session = LanguageModelSession(instructions: instructions)

                    try await withTimeout(seconds: 15) {
                        var lastLength = 0
                        let stream = session.streamResponse(to: userPrompt)
                        for try await partial in stream {
                            let current = partial.content
                            if current.count > lastLength {
                                let delta = String(current.dropFirst(lastLength))
                                continuation.yield(delta)
                                lastLength = current.count
                            }
                        }
                    }
                    continuation.finish()
                    return
                } catch {
                    // FoundationModels failed (sandbox, timeout, etc.)
                }

                // Full fallback to local provider
                do {
                    let localResponse = try await fallback.chat(messages: messages)
                    continuation.yield(localResponse)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
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

    // MARK: - Timeout Helper

    private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            // Return whichever finishes first
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
