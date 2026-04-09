import Foundation

/// Stub Apple Intelligence provider.
/// On iOS 26+ devices with Apple Intelligence, this would use FoundationModels.
/// Without it, this provides a rule-based interview that extracts structured
/// person data from user messages and emits ```json blocks that the
/// InterviewView can parse — making the default onboarding path functional.
struct AppleIntelligenceProvider: AIProvider {

    var isAvailable: Bool { true }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let response = generateLocalResponse(messages: messages)
            let words = response.components(separatedBy: " ")
            Task {
                for (i, word) in words.enumerated() {
                    try Task.checkCancellation()
                    let chunk = i == 0 ? word : " " + word
                    continuation.yield(chunk)
                    try await Task.sleep(for: .milliseconds(20))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Local Response Generation

    /// Rule-based interview that parses user input and emits JSON extraction blocks.
    /// Follows a state machine keyed on the number of user messages.
    private func generateLocalResponse(messages: [AIMessage]) -> String {
        let userMessages = messages.filter { $0.role == .user }
        let assistantMessages = messages.filter { $0.role == .assistant }
        let lastMessage = userMessages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let turnCount = userMessages.count

        // Accumulate person data across turns
        // We track state by scanning prior assistant messages for context
        switch turnCount {
        case 1:
            // First user message — their name
            return "Great! When were you born? Just the year is fine."

        case 2:
            // Second message — birth year. Now we have enough for the root person.
            let name = userMessages[0].content.trimmingCharacters(in: .whitespacesAndNewlines)
            let yearText = lastMessage
            let nameParts = name.components(separatedBy: " ")
            let firstName = nameParts.first ?? name
            let lastName = nameParts.count > 1 ? nameParts.last : nil
            let middleName = nameParts.count > 2 ? nameParts.dropFirst().dropLast().joined(separator: " ") : nil
            let birthYear = Int(yearText.filter(\.isNumber))

            let json = buildPersonJSON(
                firstName: firstName,
                middleName: middleName,
                lastName: lastName,
                birthYear: birthYear,
                gender: nil,
                isLiving: true,
                relationships: []
            )

            return "Got it, \(firstName)! I've added you to the tree.\n\n\(json)\n\nNow tell me about your parents. What are their names?"

        case 3:
            // Third message — parents
            let parentNames = parseNameList(lastMessage)
            let rootName = userMessages[0].content.trimmingCharacters(in: .whitespacesAndNewlines)
            let rootFirst = rootName.components(separatedBy: " ").first ?? rootName

            var output = "Thanks! I've added your parents.\n\n"
            for (i, name) in parentNames.enumerated() {
                let parts = name.components(separatedBy: " ")
                let first = parts.first ?? name
                let last = parts.count > 1 ? parts.last : nil
                let gender: String? = i == 0 ? "male" : (parentNames.count > 1 ? "female" : nil)
                let json = buildPersonJSON(
                    firstName: first, middleName: nil, lastName: last,
                    birthYear: nil, gender: gender, isLiving: nil,
                    relationships: [("parent", rootFirst)]
                )
                output += "\(json)\n\n"
            }
            output += "Do you have a spouse or partner? If so, what's their name?"
            return output

        case 4:
            // Fourth message — spouse
            let spouseName = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            let rootName = userMessages[0].content.trimmingCharacters(in: .whitespacesAndNewlines)
            let rootFirst = rootName.components(separatedBy: " ").first ?? rootName

            if spouseName.lowercased().hasPrefix("no") || spouseName.lowercased() == "skip" {
                return "No problem! Do you have any siblings? Tell me their names."
            }

            let parts = spouseName.components(separatedBy: " ")
            let first = parts.first ?? spouseName
            let last = parts.count > 1 ? parts.last : nil
            let json = buildPersonJSON(
                firstName: first, middleName: nil, lastName: last,
                birthYear: nil, gender: nil, isLiving: nil,
                relationships: [("spouse", rootFirst)]
            )

            return "Added your spouse!\n\n\(json)\n\nDo you have any children? Tell me their names."

        case 5:
            // Fifth message — children
            let childNames = parseNameList(lastMessage)
            let rootName = userMessages[0].content.trimmingCharacters(in: .whitespacesAndNewlines)
            let rootFirst = rootName.components(separatedBy: " ").first ?? rootName

            if childNames.isEmpty || lastMessage.lowercased().hasPrefix("no") {
                return "That's a great start to your family tree! You can add more people anytime from the tree view. Tap Done when you're ready."
            }

            var output = "Added your children!\n\n"
            for name in childNames {
                let parts = name.components(separatedBy: " ")
                let first = parts.first ?? name
                let last = parts.count > 1 ? parts.last : nil
                let json = buildPersonJSON(
                    firstName: first, middleName: nil, lastName: last,
                    birthYear: nil, gender: nil, isLiving: nil,
                    relationships: [("child", rootFirst)]
                )
                output += "\(json)\n\n"
            }
            output += "Great start! Would you like to add anyone else, or tap Done to see your tree?"
            return output

        default:
            // Subsequent messages — try to parse as a new person
            let names = parseNameList(lastMessage)
            if !names.isEmpty && !lastMessage.lowercased().hasPrefix("no") && !lastMessage.lowercased().hasPrefix("done") {
                var output = "Added!\n\n"
                for name in names {
                    let parts = name.components(separatedBy: " ")
                    let first = parts.first ?? name
                    let last = parts.count > 1 ? parts.last : nil
                    let json = buildPersonJSON(
                        firstName: first, middleName: nil, lastName: last,
                        birthYear: nil, gender: nil, isLiving: nil,
                        relationships: []
                    )
                    output += "\(json)\n\n"
                }
                output += "Anyone else? Or tap Done to finish."
                return output
            }
            return "Tap Done whenever you're ready to see your family tree!"
        }
    }

    // MARK: - Helpers

    private func buildPersonJSON(
        firstName: String,
        middleName: String?,
        lastName: String?,
        birthYear: Int?,
        gender: String?,
        isLiving: Bool?,
        relationships: [(type: String, personName: String)]
    ) -> String {
        let relsJSON = relationships.map { rel in
            #"{"type": "\#(rel.type)", "personName": "\#(rel.personName)"}"#
        }.joined(separator: ", ")

        return """
        ```json
        {
            "firstName": "\(firstName)",
            "middleName": \(middleName.map { #""\#($0)""# } ?? "null"),
            "lastName": \(lastName.map { #""\#($0)""# } ?? "null"),
            "nickname": null,
            "birthYear": \(birthYear.map(String.init) ?? "null"),
            "birthPlace": null,
            "isLiving": \(isLiving.map { $0 ? "true" : "false" } ?? "true"),
            "deathYear": null,
            "gender": \(gender.map { #""\#($0)""# } ?? "null"),
            "relationships": [\(relsJSON)],
            "isComplete": true
        }
        ```
        """
    }

    /// Parse a comma/and-separated list of names from user input.
    private func parseNameList(_ input: String) -> [String] {
        let cleaned = input
            .replacingOccurrences(of: " and ", with: ", ")
            .replacingOccurrences(of: " & ", with: ", ")

        return cleaned
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 1 }
    }
}
