import Foundation
import GRDB

/// Extracted person from AI response.
struct ExtractedPerson: Codable, Sendable {
    let firstName: String
    let lastName: String?
    let role: String?           // "self", "parent", "spouse", "child", "sibling", etc.
    let relatedTo: String?      // firstName of the person this relates to (cloud models)

    // Legacy fields — accepted if present but not required
    let middleName: String?
    let nickname: String?
    let birthYear: Int?
    let birthPlace: String?
    let isLiving: Bool?
    let deathYear: Int?
    let gender: String?
    let relationships: [ExtractedRelationship]?
    let isComplete: Bool?

    var isPersonComplete: Bool { isComplete ?? true }
    var livingStatus: Bool { isLiving ?? true }
    var personRelationships: [ExtractedRelationship] { relationships ?? [] }

    // CodingKeys with defaults for missing fields
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstName = try c.decode(String.self, forKey: .firstName)
        lastName = try c.decodeIfPresent(String.self, forKey: .lastName)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        relatedTo = try c.decodeIfPresent(String.self, forKey: .relatedTo)
        middleName = try c.decodeIfPresent(String.self, forKey: .middleName)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        birthYear = try c.decodeIfPresent(Int.self, forKey: .birthYear)
        birthPlace = try c.decodeIfPresent(String.self, forKey: .birthPlace)
        isLiving = try c.decodeIfPresent(Bool.self, forKey: .isLiving)
        deathYear = try c.decodeIfPresent(Int.self, forKey: .deathYear)
        gender = try c.decodeIfPresent(String.self, forKey: .gender)
        // Decode relationships only if it's actually an array of ExtractedRelationship
        // (skip if the model nested person objects instead)
        relationships = try? c.decodeIfPresent([ExtractedRelationship].self, forKey: .relationships)
        isComplete = try c.decodeIfPresent(Bool.self, forKey: .isComplete)
    }

    // For test construction
    init(firstName: String, middleName: String? = nil, lastName: String? = nil,
         nickname: String? = nil, birthYear: Int? = nil, birthPlace: String? = nil,
         isLiving: Bool? = true, deathYear: Int? = nil, gender: String? = nil,
         relationships: [ExtractedRelationship]? = nil, isComplete: Bool? = true,
         role: String? = nil, relatedTo: String? = nil) {
        self.firstName = firstName; self.middleName = middleName; self.lastName = lastName
        self.nickname = nickname; self.birthYear = birthYear; self.birthPlace = birthPlace
        self.isLiving = isLiving; self.deathYear = deathYear; self.gender = gender
        self.relationships = relationships; self.isComplete = isComplete; self.role = role
        self.relatedTo = relatedTo
    }
}

struct ExtractedRelationship: Codable, Sendable {
    let type: String
    let personName: String
}

struct InterviewService: Sendable {
    let dbQueue: DatabaseQueue
    let aiProvider: any AIProvider

    /// Exposed for device integration tests
    var testableSystemPrompt: String { systemPrompt }

    private static let baseCompactPrompt = "Extract names from input. Output ```json blocks with firstName, lastName, role, relatedTo. role: self/parent/spouse/child/sibling. relatedTo: firstName of who they relate to. One block per person. Only names from input. Be brief."

    private static let baseCloudPrompt = """
    You are a family tree assistant. Extract people from user input and output JSON.

    For each NEW person, output a ```json block with: firstName, lastName, role, relatedTo.
    - role: self/parent/spouse/child/sibling/grandchild
    - relatedTo: firstName of the existing person they connect to

    Rules:
    - One JSON block per NEW person only. Do NOT re-output existing people.
    - When no last name given, infer from the family context.
    - Never invent names. Only extract what the user actually said.
    - Say a friendly message, then JSON blocks, then ask what's next.
    """

    /// Build the system prompt with the current tree state included.
    private var systemPrompt: String {
        let isCloud = aiProvider is AnthropicProvider || aiProvider is OpenAIProvider
        let base = isCloud ? Self.baseCloudPrompt : Self.baseCompactPrompt
        let treeSummary = buildTreeSummary(compact: !isCloud)
        if treeSummary.isEmpty {
            return base
        }
        return base + "\n\nCurrent family tree:\n" + treeSummary
    }

    /// Serialize the current tree as a compact text summary for the AI.
    /// On-device: ultra-compact (name + relationship only, ~15 chars/person).
    /// Cloud: includes last names and relationship details.
    private func buildTreeSummary(compact: Bool) -> String {
        let people: [Person]
        let relationships: [Relationship]
        do {
            people = try dbQueue.read { db in try Person.fetchAll(db) }
            relationships = try dbQueue.read { db in try Relationship.fetchAll(db) }
        } catch {
            return ""
        }

        guard !people.isEmpty else { return "" }

        let personMap = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })

        // Build adjacency: who is parent/spouse/sibling of whom
        var lines: [String] = []

        for person in people {
            let parentRels = relationships.filter { $0.type == .parent && $0.fromPersonId == person.id }
            let children = parentRels.compactMap { personMap[$0.toPersonId]?.firstName }

            let spouseRels = relationships.filter { $0.type == .spouse && $0.fromPersonId == person.id }
            let spouses = spouseRels.compactMap { personMap[$0.toPersonId]?.firstName }

            if compact {
                // Ultra-compact: "John Smith: spouse=Mary, children=Michael,Sarah"
                var parts: [String] = []
                if !spouses.isEmpty { parts.append("sp=\(spouses.joined(separator: ","))") }
                if !children.isEmpty { parts.append("ch=\(children.joined(separator: ","))") }
                if !parts.isEmpty {
                    lines.append("\(person.firstName): \(parts.joined(separator: " "))")
                } else {
                    lines.append(person.firstName)
                }
            } else {
                // Cloud: more readable
                var parts: [String] = []
                if !spouses.isEmpty { parts.append("spouse: \(spouses.joined(separator: ", "))") }
                if !children.isEmpty { parts.append("children: \(children.joined(separator: ", "))") }
                if !parts.isEmpty {
                    lines.append("- \(person.displayName): \(parts.joined(separator: "; "))")
                } else {
                    lines.append("- \(person.displayName)")
                }
            }
        }

        // On-device: ~50 people fits in 4K tokens. Cloud: practically unlimited.
        let maxLines = compact ? 50 : 500
        if lines.count > maxLines {
            return lines.prefix(maxLines).joined(separator: "\n") + "\n... and \(lines.count - maxLines) more"
        }

        return lines.joined(separator: "\n")
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
            existing.isLiving = extracted.livingStatus
            existing.updatedAt = now

            try dbQueue.write { db in
                try existing.update(db)
            }
            person = existing
        } else {
            // Create new person — normalize capitalization
            let newPerson = Person(
                id: UUID(),
                firstName: capitalizeName(extracted.firstName),
                middleName: extracted.middleName.map(capitalizeName),
                lastName: extracted.lastName.map(capitalizeName),
                nickname: extracted.nickname,
                birthDate: nil,
                birthYear: extracted.birthYear,
                deathDate: nil,
                deathYear: extracted.deathYear,
                isLiving: extracted.livingStatus,
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

        // Link relationship based on role (relative to root person)
        let treeService = TreeService(dbQueue: dbQueue)
        if let role = extracted.role?.lowercased(), role != "self" {
            try linkByRole(person: person, role: role, relatedTo: extracted.relatedTo, treeService: treeService)
        }

        // Also process legacy relationship array if present
        for rel in extracted.personRelationships {
            try linkRelationship(
                extractedPerson: person,
                relationship: rel,
                treeService: treeService
            )
        }

        return person
    }

    /// Link a person based on their role and relatedTo field.
    /// If relatedTo is specified, links to that person. Otherwise links to root.
    private func linkByRole(person: Person, role: String, relatedTo: String? = nil, treeService: TreeService) throws {
        // Find the target person to link to
        let target: Person?
        if let relName = relatedTo, !relName.isEmpty {
            // Look up by firstName. If multiple matches, prefer most recently added.
            target = try dbQueue.read { db -> Person? in
                let allPeople = try Person.order(Column("createdAt").desc).fetchAll(db)
                return allPeople.first { $0.firstName.lowercased() == relName.lowercased() }
            }
        } else {
            // Default: link to root person
            target = try dbQueue.read { db -> Person? in
                let settings = try AppSettings.current(db)
                if let rootId = settings.rootPersonId {
                    return try Person.fetchOne(db, key: rootId)
                }
                return try Person.order(Column("createdAt")).fetchOne(db)
            }
        }
        guard let linkTo = target, linkTo.id != person.id else { return }

        do {
            switch role {
            case "parent":
                try treeService.addRelationship(from: person.id, to: linkTo.id, type: .parent)
            case "child", "grandchild":
                try treeService.addRelationship(from: linkTo.id, to: person.id, type: .parent)
            case "spouse", "wife", "husband":
                try treeService.addRelationship(from: linkTo.id, to: person.id, type: .spouse)
            case "sibling":
                try treeService.addRelationship(from: linkTo.id, to: person.id, type: .sibling)
            default:
                break
            }
        } catch is TreeServiceError {
            // Relationship already exists — fine
        }
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

    // MARK: - Name Normalization

    /// Capitalize first letter, lowercase rest. Handles all-caps from AI models.
    private func capitalizeName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        // If it's all uppercase or all lowercase, title-case it
        if trimmed == trimmed.uppercased() || trimmed == trimmed.lowercased() {
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
        }
        return trimmed // Already mixed case, leave it
    }

    // MARK: - JSON Extraction

    private func extractPersonJSON(from text: String) -> ExtractedPerson? {
        let pattern = #"```json[^\n]*\n([\s\S]*?)\n\s*```"#
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
