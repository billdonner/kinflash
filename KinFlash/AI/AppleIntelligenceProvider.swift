import Foundation

/// Stub Apple Intelligence provider.
/// On iOS 26+ devices with Apple Intelligence, this would use FoundationModels.
/// On devices without it, it falls back to a simple local response generator
/// that can still conduct basic interviews without network access.
struct AppleIntelligenceProvider: AIProvider {

    var isAvailable: Bool {
        // In a real build targeting iOS 26, this would check:
        //   SystemLanguageModel.default.isAvailable
        // For now, we provide a basic fallback that works without FoundationModels.
        true
    }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Simulate token-by-token delivery
            let response = generateLocalResponse(messages: messages)
            let words = response.components(separatedBy: " ")
            Task {
                for (i, word) in words.enumerated() {
                    try Task.checkCancellation()
                    let chunk = i == 0 ? word : " " + word
                    continuation.yield(chunk)
                    try await Task.sleep(for: .milliseconds(30))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Local Response Generation

    /// Basic interview logic that works without any AI model.
    /// Follows a simple state machine to gather family member information.
    private func generateLocalResponse(messages: [AIMessage]) -> String {
        let userMessages = messages.filter { $0.role == .user }
        let lastMessage = userMessages.last?.content ?? ""
        let messageCount = userMessages.count

        switch messageCount {
        case 1:
            // First user message — assume it's their name
            let name = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = name.components(separatedBy: " ")
            let firstName = parts.first ?? name
            return "Great, \(firstName)! When were you born? Just the year is fine if you're not sure of the exact date."

        case 2:
            // Second message — assume birth year
            return "Got it! Are you male, female, or would you prefer not to say?"

        case 3:
            // Third message — gender
            return "Thanks! Now let's talk about your family. Who are your parents? You can tell me their names."

        case 4:
            // Fourth message — parents
            return "Would you like to tell me about your spouse or partner? If not, we can talk about siblings."

        case 5:
            // Fifth message — spouse or siblings
            return "Do you have any children? Tell me their names."

        default:
            if messageCount % 2 == 0 {
                return "Would you like to add another family member, or are you done for now?"
            } else {
                return "Tell me more about them — name, approximate birth year, and how they're related to someone already in your tree."
            }
        }
    }
}
