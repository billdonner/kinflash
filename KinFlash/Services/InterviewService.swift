import Foundation
import GRDB

struct ExtractedPerson: Codable, Sendable {
    let firstName: String
    let middleName: String?
    let lastName: String?
    let nickname: String?
    let birthYear: Int?
    let birthPlace: String?
    let isLiving: Bool
    let deathYear: Int?
    let gender: String?
    let relationships: [ExtractedRelationship]
    let isComplete: Bool
}

struct ExtractedRelationship: Codable, Sendable {
    let type: String
    let personName: String
}

struct InterviewService: Sendable {
    let dbQueue: DatabaseQueue
    let aiProvider: any AIProvider

    private var systemPrompt: String {
        """
        You are a friendly family tree interview assistant for KinFlash. Your job is to help \
        the user build their family tree through natural conversation.

        For each person mentioned, extract the following information:
        - First name, middle name (if mentioned), last name
        - Nickname (if mentioned)
        - Birth year or approximate era
        - Birth place (if mentioned)
        - Whether the person is living or deceased
        - Death year (if deceased and mentioned)
        - Gender (male, female, nonBinary, or unknown)
        - Relationships to other people already mentioned

        After gathering enough information about one person, ask if they'd like to add another \
        family member or if they're done for now.

        Be conversational and warm. Ask one or two questions at a time, not a long checklist.

        When you have extracted person data, include it in your response as a JSON block \
        wrapped in ```json ... ``` markers with this structure:
        {
            "firstName": "John",
            "middleName": "Robert",
            "lastName": "Smith",
            "nickname": null,
            "birthYear": 1945,
            "birthPlace": "Chicago, Illinois",
            "isLiving": false,
            "deathYear": 2018,
            "gender": "male",
            "relationships": [
                {"type": "spouse", "personName": "Mary Jones"},
                {"type": "child", "personName": "Michael Smith"}
            ],
            "isComplete": true
        }

        Only include the JSON block when you have enough information to create or update a person. \
        The isComplete field should be true when you've gathered the essential info (at minimum: name and one relationship).
        """
    }

    func processMessage(userMessage: String, conversationHistory: [AIMessage]) async throws -> (response: String, extracted: ExtractedPerson?) {
        var messages = conversationHistory
        if messages.isEmpty || messages.first?.role != .system {
            messages.insert(AIMessage(role: .system, content: systemPrompt), at: 0)
        }
        messages.append(AIMessage(role: .user, content: userMessage))

        let response = try await aiProvider.chat(messages: messages)

        // Try to extract JSON from the response
        let extracted = extractPersonJSON(from: response)

        return (response: response, extracted: extracted)
    }

    func streamMessage(userMessage: String, conversationHistory: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        var messages = conversationHistory
        if messages.isEmpty || messages.first?.role != .system {
            messages.insert(AIMessage(role: .system, content: systemPrompt), at: 0)
        }
        messages.append(AIMessage(role: .user, content: userMessage))
        return aiProvider.chatStream(messages: messages)
    }

    /// Save an extracted person to the database.
    func saveExtractedPerson(_ extracted: ExtractedPerson) throws -> Person {
        let gender: Gender?
        switch extracted.gender?.lowercased() {
        case "male": gender = .male
        case "female": gender = .female
        case "nonbinary": gender = .nonBinary
        default: gender = .unknown
        }

        let now = Date()
        let person = Person(
            id: UUID(),
            firstName: extracted.firstName,
            middleName: extracted.middleName,
            lastName: extracted.lastName,
            nickname: extracted.nickname,
            birthDate: nil,
            birthYear: extracted.birthYear,
            deathDate: nil,
            deathYear: extracted.deathYear,
            isLiving: extracted.isLiving,
            birthPlace: extracted.birthPlace,
            gender: gender,
            notes: nil,
            profilePhotoFilename: nil,
            gedcomId: nil,
            createdAt: now,
            updatedAt: now
        )

        try dbQueue.write { db in
            try person.insert(db)
        }

        return person
    }

    // MARK: - Private

    private func extractPersonJSON(from text: String) -> ExtractedPerson? {
        // Look for ```json ... ``` block
        let pattern = #"```json\s*([\s\S]*?)\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let jsonString = String(text[range])
        guard let data = jsonString.data(using: .utf8) else { return nil }

        return try? JSONDecoder().decode(ExtractedPerson.self, from: data)
    }
}
