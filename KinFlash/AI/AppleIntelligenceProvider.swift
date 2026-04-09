import Foundation
import FoundationModels

/// Apple Intelligence provider using on-device FoundationModels (iOS 26+).
/// Falls back to LocalInterviewProvider with a visible warning if FoundationModels fails.
struct AppleIntelligenceProvider: AIProvider {

    private let fallback = LocalInterviewProvider()

    var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    func chat(messages: [AIMessage]) async throws -> String {
        guard isAvailable else {
            return "[Apple Intelligence is not available on this device. Using basic mode.]\n\n"
                + (try await fallback.chat(messages: messages))
        }

        do {
            return try await withTimeout(seconds: 15) {
                let (instructions, userPrompt) = buildPrompt(from: messages)
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: userPrompt)
                return response.content
            }
        } catch {
            return "[Apple Intelligence failed: \(error.localizedDescription). Falling back to basic mode.]\n\n"
                + (try await fallback.chat(messages: messages))
        }
    }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        guard isAvailable else {
            return AsyncThrowingStream { continuation in
                Task {
                    continuation.yield("[Apple Intelligence is not available on this device. Using basic mode.]\n\n")
                    do {
                        let response = try await fallback.chat(messages: messages)
                        continuation.yield(response)
                    } catch {}
                    continuation.finish()
                }
            }
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
                    // FoundationModels failed — warn user, then fall back
                    continuation.yield("\n\n[Apple Intelligence failed: \(error.localizedDescription). Switching to basic mode.]\n\n")
                }

                // Fallback with visible notice
                do {
                    let localResponse = try await fallback.chat(messages: messages)
                    continuation.yield(localResponse)
                } catch {}
                continuation.finish()
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

    // MARK: - Timeout

    private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
