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
    let type: String      // "parent", "spouse", "sibling", "child"
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

        Relationship types must be from the perspective of the extracted person:
        - "parent" means this person IS A PARENT OF the named person
        - "child" means this person IS A CHILD OF the named person
        - "spouse" means this person is married to the named person
        - "sibling" means this person is a sibling of the named person

        Only include the JSON block when you have enough information to create or update a person. \
        The isComplete field should be true when you've gathered the essential info (at minimum: name and one relationship).
        """
    }

    // MARK: - Message Processing

    func processMessage(userMessage: String, conversationHistory: [AIMessage]) async throws -> (response: String, extracted: ExtractedPerson?) {
        var messages = conversationHistory
        if messages.isEmpty || messages.first?.role != .system {
            messages.insert(AIMessage(role: .system, content: systemPrompt), at: 0)
        }
        messages.append(AIMessage(role: .user, content: userMessage))

        let response = try await aiProvider.chat(messages: messages)
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

    // MARK: - Save Extracted Person + Relationships

    /// Save an extracted person to the database, linking relationships to existing people.
    /// Uses fuzzy matching to find existing people by name. Returns the saved/updated Person.
    func saveExtractedPerson(_ extracted: ExtractedPerson) throws -> Person {
        let gender: Gender?
        switch extracted.gender?.lowercased() {
        case "male": gender = .male
        case "female": gender = .female
        case "nonbinary": gender = .nonBinary
        default: gender = .unknown
        }

        let now = Date()

        // Check for existing person with fuzzy name match
        let existingPerson = try findExistingPerson(
            firstName: extracted.firstName,
            lastName: extracted.lastName,
            birthYear: extracted.birthYear
        )

        let person: Person
        if var existing = existingPerson {
            // Update existing person with any new info
            if let middle = extracted.middleName, existing.middleName == nil { existing.middleName = middle }
            if let nick = extracted.nickname, existing.nickname == nil { existing.nickname = nick }
            if let by = extracted.birthYear, existing.birthYear == nil { existing.birthYear = by }
            if let bp = extracted.birthPlace, existing.birthPlace == nil { existing.birthPlace = bp }
            if let dy = extracted.deathYear, existing.deathYear == nil { existing.deathYear = dy }
            if existing.gender == nil || existing.gender == .unknown { existing.gender = gender }
            existing.isLiving = extracted.isLiving
            existing.updatedAt = now

            try dbQueue.write { db in
                try existing.update(db)
            }
            person = existing
        } else {
            // Create new person
            let newPerson = Person(
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
                try newPerson.insert(db)
            }
            person = newPerson
        }

        // Process relationships
        let treeService = TreeService(dbQueue: dbQueue)
        for rel in extracted.relationships {
            try linkRelationship(
                extractedPerson: person,
                relationship: rel,
                treeService: treeService
            )
        }

        return person
    }

    // MARK: - Relationship Linking

    /// Link a relationship between the extracted person and a named person.
    /// Creates placeholder people for names that don't match existing records.
    private func linkRelationship(
        extractedPerson: Person,
        relationship: ExtractedRelationship,
        treeService: TreeService
    ) throws {
        // Parse the relationship target name
        let nameParts = relationship.personName.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
        let targetFirstName = nameParts.first ?? relationship.personName
        let targetLastName = nameParts.count > 1 ? nameParts.last : nil

        // Find or create the target person
        let targetPerson: Person
        if let existing = try findExistingPerson(firstName: targetFirstName, lastName: targetLastName, birthYear: nil) {
            targetPerson = existing
        } else {
            // Create a placeholder person for the relationship target
            let now = Date()
            let placeholder = Person(
                id: UUID(),
                firstName: targetFirstName,
                middleName: nameParts.count > 2 ? nameParts.dropFirst().dropLast().joined(separator: " ") : nil,
                lastName: targetLastName,
                nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now
            )
            try dbQueue.write { db in
                try placeholder.insert(db)
            }
            targetPerson = placeholder
        }

        // Create the relationship based on type
        // Types are from the extracted person's perspective
        do {
            switch relationship.type.lowercased() {
            case "parent":
                // Extracted person IS PARENT OF target
                try treeService.addRelationship(from: extractedPerson.id, to: targetPerson.id, type: .parent)
            case "child":
                // Extracted person IS CHILD OF target → target is parent of extracted
                try treeService.addRelationship(from: targetPerson.id, to: extractedPerson.id, type: .parent)
            case "spouse":
                try treeService.addRelationship(from: extractedPerson.id, to: targetPerson.id, type: .spouse)
            case "sibling":
                try treeService.addRelationship(from: extractedPerson.id, to: targetPerson.id, type: .sibling)
            default:
                break // Unknown relationship type, skip
            }
        } catch is TreeServiceError {
            // Ignore duplicate/self relationship errors — they mean the link already exists
        }
    }

    // MARK: - Fuzzy Matching

    /// Find an existing person by fuzzy name match.
    /// Matches on first name (case-insensitive) + last name (case-insensitive) + optional birth year (within 2 years).
    private func findExistingPerson(firstName: String, lastName: String?, birthYear: Int?) throws -> Person? {
        try dbQueue.read { db in
            let allPeople = try Person.fetchAll(db)

            let firstLower = firstName.lowercased()

            return allPeople.first { person in
                // First name must match (case-insensitive)
                guard person.firstName.lowercased() == firstLower else { return false }

                // Last name match (both nil = match, both present must match)
                if let extractedLast = lastName, let personLast = person.lastName {
                    guard extractedLast.lowercased() == personLast.lowercased() else { return false }
                } else if lastName != nil && person.lastName == nil {
                    return false
                } else if lastName == nil && person.lastName != nil {
                    // Extracted has no last name — still consider a match on first name alone
                    // (common in interview where user says "my mom Helen")
                }

                // Birth year proximity check (if both present)
                if let eby = birthYear, let pby = person.birthYear {
                    guard abs(eby - pby) <= 2 else { return false }
                }

                return true
            }
        }
    }

    // MARK: - JSON Extraction

    private func extractPersonJSON(from text: String) -> ExtractedPerson? {
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
