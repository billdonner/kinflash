import Foundation

/// On-device interview provider that works without any AI model.
/// Uses pattern matching to extract people and relationships from natural
/// conversational input, and drives a multi-phase interview covering
/// immediate family, extended family, grandchildren, and cousins.
struct AppleIntelligenceProvider: AIProvider {

    var isAvailable: Bool { true }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let response = generateResponse(messages: messages)
            let words = response.components(separatedBy: " ")
            Task {
                for (i, word) in words.enumerated() {
                    try Task.checkCancellation()
                    continuation.yield(i == 0 ? word : " " + word)
                    try await Task.sleep(for: .milliseconds(15))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Response Generation

    private func generateResponse(messages: [AIMessage]) -> String {
        let userMessages = messages.filter { $0.role == .user }
        let allAssistant = messages.filter { $0.role == .assistant }
        let lastUser = userMessages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Reconstruct what we've already asked about from assistant messages
        let askedText = allAssistant.map(\.content).joined(separator: " ").lowercased()
        let allText = messages.map(\.content).joined(separator: " ").lowercased()

        // Phase detection: what have we covered?
        let askedName = askedText.contains("full name")
        let askedBirthYear = askedText.contains("born") || askedText.contains("birth year")
        let askedParents = askedText.contains("parent")
        let askedSpouse = askedText.contains("spouse") || askedText.contains("married") || askedText.contains("partner")
        let askedChildren = askedText.contains("children") || askedText.contains("kids") || askedText.contains("sons") || askedText.contains("daughters")
        let askedSiblings = askedText.contains("siblings") || askedText.contains("brothers") || askedText.contains("sisters")
        let askedGrandchildren = askedText.contains("grandchild") || askedText.contains("grandkid")
        let askedExtended = askedText.contains("uncle") || askedText.contains("aunt") || askedText.contains("cousin")

        // Get root person name from first user message
        let rootName: String
        if let first = userMessages.first?.content.trimmingCharacters(in: .whitespacesAndNewlines) {
            rootName = first
        } else {
            rootName = ""
        }
        let rootFirst = capitalizeName(rootName.components(separatedBy: " ").first ?? rootName)

        // If this is turn 1, just ask for name
        guard userMessages.count > 0 else {
            return "Hi! I'm going to help you build your family tree. Let's start with you. What's your full name?"
        }

        // Try to extract data from the latest user message
        var jsonBlocks = ""
        let extracted = extractFromMessage(lastUser, rootFirst: rootFirst, context: askedText)
        for block in extracted {
            jsonBlocks += block + "\n\n"
        }

        // Determine next question based on what we haven't asked
        let nextQuestion: String
        if !askedBirthYear && userMessages.count == 1 {
            // First message was name — emit the person and ask birth year
            let nameParts = lastUser.components(separatedBy: " ").map { capitalizeName($0) }
            let fn = nameParts.first ?? lastUser
            let ln = nameParts.count > 1 ? nameParts.last : nil
            let mn = nameParts.count > 2 ? nameParts.dropFirst().dropLast().joined(separator: " ") : nil
            jsonBlocks = buildPersonJSON(firstName: fn, middleName: mn, lastName: ln,
                                         birthYear: nil, gender: nil, isLiving: true, relationships: [])
            nextQuestion = "Nice to meet you, \(fn)! What year were you born?"
        } else if !askedParents {
            nextQuestion = "Tell me about your parents. What are their full names? (e.g., \"Richard Donner and Rose Donner\")"
        } else if !askedSpouse {
            nextQuestion = "Are you married or do you have a partner? What's their full name? (Say \"no\" to skip)"
        } else if !askedChildren {
            nextQuestion = "Do you have any children? Tell me their full names, separated by commas."
        } else if !askedSiblings {
            nextQuestion = "Do you have any brothers or sisters? What are their names?"
        } else if !askedGrandchildren {
            nextQuestion = "Do any of your children have kids (your grandchildren)? Tell me which child and their kids' names. (e.g., \"Andrew's kids are Teddy and Max\")"
        } else if !askedExtended {
            nextQuestion = "Let's go wider. Do you have any aunts, uncles, or cousins you'd like to add? Tell me their names and how they're related. (e.g., \"Uncle Frank Donner, my dad's brother\")"
        } else {
            nextQuestion = "Anyone else you'd like to add? You can tell me about nieces, nephews, in-laws, or anyone else. Or tap Done to see your tree!"
        }

        // Build response: acknowledgment + JSON blocks + next question
        let ack = extracted.isEmpty ? "" : "Got it! "
        return "\(ack)\(jsonBlocks)\(nextQuestion)"
    }

    // MARK: - Content-Aware Extraction

    /// Parse the user's message and return JSON blocks for each person found.
    private func extractFromMessage(_ text: String, rootFirst: String, context: String) -> [String] {
        let lower = text.lowercased()
        var blocks: [String] = []

        // Skip non-content responses
        if isNegativeOrEmpty(lower) { return [] }

        // Check for birth year response (just a number)
        if let year = extractYear(from: text), text.filter(\.isLetter).count < 5 {
            // This is a birth year answer — don't create a new person, just acknowledge
            return []
        }

        // Pattern: "X's kids are Y and Z" or "X's children: Y, Z"
        let possessiveKids = #"(\w+)'s\s+(?:kids?|children)\s+(?:are|:)\s+(.+)"#
        if let match = firstMatch(pattern: possessiveKids, in: text) {
            let parentFirst = capitalizeName(match[1])
            let kidNames = parseNameList(match[2])
            for name in kidNames {
                let parts = splitName(name)
                blocks.append(buildPersonJSON(
                    firstName: parts.first, middleName: parts.middle, lastName: parts.last,
                    birthYear: nil, gender: nil, isLiving: true,
                    relationships: [("child", parentFirst)]
                ))
            }
            return blocks
        }

        // Pattern: "Uncle/Aunt X, my dad's/mom's brother/sister"
        let relativePattern = #"(?:uncle|aunt)\s+(\w[\w\s]*?)(?:,\s*my\s+(\w+)'s\s+(brother|sister))?"#
        for match in allMatches(pattern: relativePattern, in: text) {
            let name = match[1].trimmingCharacters(in: .whitespaces)
            let parts = splitName(name)
            // Try to figure out parent relationship
            let parentRef = match.count > 2 ? capitalizeName(match[2]) : rootFirst
            let relType = match.count > 3 && !match[3].isEmpty ? "sibling" : "sibling"
            blocks.append(buildPersonJSON(
                firstName: parts.first, middleName: parts.middle, lastName: parts.last,
                birthYear: nil, gender: match[0].lowercased().hasPrefix("uncle") ? "male" : "female",
                isLiving: nil,
                relationships: [("sibling", parentRef)]
            ))
        }
        if !blocks.isEmpty { return blocks }

        // Pattern: "cousin X" or "my cousin X"
        let cousinPattern = #"(?:my\s+)?cousin\s+(\w[\w\s]*?)(?:\s*[,.]|$)"#
        for match in allMatches(pattern: cousinPattern, in: text) {
            let name = match[1].trimmingCharacters(in: .whitespaces)
            let parts = splitName(name)
            blocks.append(buildPersonJSON(
                firstName: parts.first, middleName: parts.middle, lastName: parts.last,
                birthYear: nil, gender: nil, isLiving: nil, relationships: []
            ))
        }
        if !blocks.isEmpty { return blocks }

        // Pattern: "my [relation] [name]" — e.g. "my wife Sarah", "my brother Tom"
        let myRelPattern = #"my\s+(wife|husband|spouse|partner|brother|sister|son|daughter|mom|mother|dad|father|ex|nephew|niece)\s+(\w[\w\s]*?)(?:\s*[,.]|$)"#
        for match in allMatches(pattern: myRelPattern, in: text) {
            let relWord = match[1].lowercased()
            let name = match[2].trimmingCharacters(in: .whitespaces)
            let parts = splitName(name)
            let (relType, gender) = relationWordToType(relWord, rootFirst: rootFirst)
            blocks.append(buildPersonJSON(
                firstName: parts.first, middleName: parts.middle, lastName: parts.last,
                birthYear: nil, gender: gender, isLiving: nil,
                relationships: relType.map { [($0.type, $0.target)] } ?? []
            ))
        }
        if !blocks.isEmpty { return blocks }

        // Determine relationship from context (what was the last question about?)
        let relFromContext = inferRelationshipFromContext(context, rootFirst: rootFirst)

        // Default: parse as comma/and-separated name list
        let names = parseNameList(text)
        for name in names {
            let parts = splitName(name)
            // Only create if it looks like a real name (capitalized, 1-3 words, no question marks)
            if looksLikeName(parts.first) {
                blocks.append(buildPersonJSON(
                    firstName: parts.first, middleName: parts.middle, lastName: parts.last,
                    birthYear: nil, gender: nil, isLiving: nil,
                    relationships: relFromContext.map { [($0.type, $0.target)] } ?? []
                ))
            }
        }

        return blocks
    }

    // MARK: - Name Parsing

    private struct NameParts {
        let first: String
        let middle: String?
        let last: String?
    }

    private func splitName(_ raw: String) -> NameParts {
        let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { capitalizeName($0) }

        switch words.count {
        case 0: return NameParts(first: "Unknown", middle: nil, last: nil)
        case 1: return NameParts(first: words[0], middle: nil, last: nil)
        case 2: return NameParts(first: words[0], middle: nil, last: words[1])
        default:
            return NameParts(first: words[0],
                             middle: words[1..<(words.count - 1)].joined(separator: " "),
                             last: words.last)
        }
    }

    private func capitalizeName(_ name: String) -> String {
        guard !name.isEmpty else { return name }
        // Handle already-capitalized names
        if name.first?.isUppercase == true { return name }
        return name.prefix(1).uppercased() + name.dropFirst().lowercased()
    }

    /// Parse a comma/and-separated list of names, filtering out non-name content.
    private func parseNameList(_ input: String) -> [String] {
        // Remove common non-name phrases
        var cleaned = input
        let removePatterns = [
            #"(?:I\s+)?(?:have|got)\s+\d+\s+\w+"#,   // "I have 3 sons"
            #"their\s+names?\s+(?:are|is)"#,           // "their names are"
            #"(?:named?|called)"#,                      // "named" / "called"
            #"(?:yes|yeah|yep|sure)[,.]?\s*"#,          // "yes, ..."
        ]
        for pattern in removePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
            }
        }

        cleaned = cleaned
            .replacingOccurrences(of: " and ", with: ", ")
            .replacingOccurrences(of: " & ", with: ", ")

        return cleaned
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { looksLikeName($0) }
    }

    /// Returns true if the string looks like a person's name.
    private func looksLikeName(_ text: String?) -> Bool {
        guard let text = text, !text.isEmpty else { return false }
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        // A name is 1-4 words, each word is letters only (plus hyphen/apostrophe), no question marks
        guard words.count >= 1 && words.count <= 4 else { return false }
        if text.contains("?") || text.contains("!") { return false }
        let nameChars = CharacterSet.letters.union(CharacterSet(charactersIn: "-'"))
        for word in words {
            if word.unicodeScalars.contains(where: { !nameChars.contains($0) }) { return false }
        }
        // Reject common non-name words
        let nonNames: Set<String> = ["no", "nope", "none", "skip", "done", "yes", "yeah", "yep",
                                      "my", "the", "from", "with", "don't", "have", "had", "was"]
        if words.count == 1 && nonNames.contains(words[0].lowercased()) { return false }
        return true
    }

    private func isNegativeOrEmpty(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let negatives: Set<String> = ["no", "nope", "none", "skip", "done", "no thanks", "not really",
                                       "that's it", "that's all", "i'm done", "im done", "nah"]
        return trimmed.isEmpty || negatives.contains(trimmed)
    }

    private func extractYear(from text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        guard digits.count == 4, let year = Int(digits) else { return nil }
        return (1900...2026).contains(year) ? year : nil
    }

    // MARK: - Relationship Inference

    private struct RelInfo {
        let type: String
        let target: String
    }

    private func relationWordToType(_ word: String, rootFirst: String) -> (relType: RelInfo?, gender: String?) {
        switch word {
        case "wife", "spouse", "partner", "husband", "ex":
            return (RelInfo(type: "spouse", target: rootFirst),
                    word == "wife" ? "female" : word == "husband" ? "male" : nil)
        case "brother", "sister":
            return (RelInfo(type: "sibling", target: rootFirst),
                    word == "brother" ? "male" : "female")
        case "son", "daughter":
            return (RelInfo(type: "child", target: rootFirst),
                    word == "son" ? "male" : "female")
        case "mom", "mother":
            return (RelInfo(type: "parent", target: rootFirst), "female")
        case "dad", "father":
            return (RelInfo(type: "parent", target: rootFirst), "male")
        case "nephew":
            return (nil, "male")
        case "niece":
            return (nil, "female")
        default:
            return (nil, nil)
        }
    }

    /// Infer relationship type from the last assistant question context.
    private func inferRelationshipFromContext(_ context: String, rootFirst: String) -> RelInfo? {
        let lower = context.lowercased()
        // Check what was most recently discussed — scan from end of context
        // Use contains() to handle plurals and partial matches
        let checks: [(keywords: [String], rel: RelInfo)] = [
            (["grandchild", "grandkid"], RelInfo(type: "child", target: rootFirst)),
            (["uncle", "aunt", "cousin"], RelInfo(type: "sibling", target: rootFirst)),
            (["children", "kids", "sons", "daughters"], RelInfo(type: "child", target: rootFirst)),
            (["siblings", "brother", "sister"], RelInfo(type: "sibling", target: rootFirst)),
            (["spouse", "married", "partner", "wife", "husband"], RelInfo(type: "spouse", target: rootFirst)),
            (["parent", "mother", "father", "mom", "dad"], RelInfo(type: "parent", target: rootFirst)),
        ]

        // Find the last-occurring keyword to determine what we most recently asked about
        var bestIndex = -1
        var bestRel: RelInfo?
        for check in checks {
            for keyword in check.keywords {
                if let range = lower.range(of: keyword, options: .backwards) {
                    let idx = lower.distance(from: lower.startIndex, to: range.lowerBound)
                    if idx > bestIndex {
                        bestIndex = idx
                        bestRel = check.rel
                    }
                }
            }
        }

        return bestRel
    }

    // MARK: - Regex Helpers

    private func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    private func allMatches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                if let r = Range(match.range(at: i), in: text) {
                    groups.append(String(text[r]))
                } else {
                    groups.append("")
                }
            }
            return groups
        }
    }

    // MARK: - JSON Builder

    private func buildPersonJSON(
        firstName: String, middleName: String?, lastName: String?,
        birthYear: Int?, gender: String?, isLiving: Bool?,
        relationships: [(type: String, personName: String)]
    ) -> String {
        let fn = capitalizeName(firstName)
        let mn = middleName.map { capitalizeName($0) }
        let ln = lastName.map { capitalizeName($0) }
        let relsJSON = relationships.map { rel in
            #"{"type": "\#(rel.type)", "personName": "\#(capitalizeName(rel.personName))"}"#
        }.joined(separator: ", ")

        return """
        ```json
        {"firstName": "\(fn)", "middleName": \(mn.map { #""\#($0)""# } ?? "null"), "lastName": \(ln.map { #""\#($0)""# } ?? "null"), "nickname": null, "birthYear": \(birthYear.map(String.init) ?? "null"), "birthPlace": null, "isLiving": \(isLiving.map { $0 ? "true" : "false" } ?? "true"), "deathYear": null, "gender": \(gender.map { #""\#($0)""# } ?? "null"), "relationships": [\(relsJSON)], "isComplete": true}
        ```
        """
    }
}
