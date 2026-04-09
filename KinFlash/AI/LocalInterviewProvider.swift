import Foundation

/// Fallback provider using rule-based parsing when Apple Intelligence
/// is unavailable. No AI model required. Kept as backup.
struct LocalInterviewProvider: AIProvider {

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

        // Phase detection: what have we covered?
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

        // Check if user is done
        if isNegativeOrEmpty(lastUser.lowercased()) || isDonePhrase(lastUser) {
            return "Your family tree is looking great! You can keep adding people anytime by coming back to the Interview tab."
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
            // First message was name — parse with nickname/age support and emit
            let parsed = parseFullNameEntry(lastUser)
            jsonBlocks = buildPersonJSON(firstName: parsed.firstName, middleName: parsed.middleName,
                                         lastName: parsed.lastName, nickname: parsed.nickname,
                                         birthYear: parsed.age.map { Calendar.current.component(.year, from: Date()) - $0 },
                                         gender: nil, isLiving: true, relationships: [])
            nextQuestion = "Nice to meet you, \(parsed.firstName)! What year were you born?"
        } else if !askedParents {
            nextQuestion = "Tell me about your parents. What are their full names? You can include nicknames in quotes and ages. (e.g., Richard \"Dick\" Donner, 95 and Rose Donner, 92)"
        } else if !askedSpouse {
            nextQuestion = "Are you married or do you have a partner? What's their full name? (Say \"no\" or \"skip\" to skip)"
        } else if !askedChildren {
            nextQuestion = "Do you have any children? Tell me their names, with ages if you know them. (e.g., Andrew Donner 45, Charlie Donner 40)"
        } else if !askedSiblings {
            nextQuestion = "Do you have any brothers or sisters? What are their names?"
        } else if !askedGrandchildren {
            nextQuestion = "Do any of your children have kids (your grandchildren)? Tell me which child and their kids' names. (e.g., \"Andrew's kids are Teddy, 12 and Max, 9\")"
        } else if !askedExtended {
            nextQuestion = "Let's go wider. Do you have any aunts, uncles, or cousins you'd like to add? Tell me their names and how they're related. (e.g., \"Uncle Frank Donner, my dad's brother\")"
        } else {
            nextQuestion = "Anyone else? You can tell me about nieces, nephews, in-laws, or anyone else. Say \"done\" or \"that's all\" when finished."
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
        if extractYear(from: text) != nil, text.filter(\.isLetter).count < 5 {
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
            let parentRef = match.count > 2 && !match[2].isEmpty ? capitalizeName(match[2]) : rootFirst
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
            if looksLikeName(name) {
                let birthYear = parts.age.map { Calendar.current.component(.year, from: Date()) - $0 }
                blocks.append(buildPersonJSON(
                    firstName: parts.first, middleName: parts.middle, lastName: parts.last,
                    nickname: parts.nickname,
                    birthYear: birthYear, gender: nil, isLiving: nil,
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
        let nickname: String?
        let age: Int?
    }

    private func splitName(_ raw: String) -> NameParts {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract nickname in quotes
        var nickname: String?
        for pattern in [#""([^"]+)""#, #"'([^']+)'"#, #"\u{201c}([^\u{201d}]+)\u{201d}"#] {
            if let match = firstMatch(pattern: pattern, in: text) {
                nickname = match[1]
                text = text.replacingOccurrences(of: match[0], with: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Extract trailing age
        var age: Int?
        let agePattern = #"[,\s]+(\d{1,3})\s*$"#
        if let match = firstMatch(pattern: agePattern, in: text), let parsed = Int(match[1]), parsed < 150 {
            age = parsed
            text = text.replacingOccurrences(of: match[0], with: "").trimmingCharacters(in: .whitespaces)
        }

        let words = text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { capitalizeName($0) }

        switch words.count {
        case 0: return NameParts(first: "Unknown", middle: nil, last: nil, nickname: nickname, age: age)
        case 1: return NameParts(first: words[0], middle: nil, last: nil, nickname: nickname, age: age)
        case 2: return NameParts(first: words[0], middle: nil, last: words[1], nickname: nickname, age: age)
        default:
            return NameParts(first: words[0],
                             middle: words[1..<(words.count - 1)].joined(separator: " "),
                             last: words.last, nickname: nickname, age: age)
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
            #"(?:I\s+)?(?:have|got)\s+\d+\s+\w+"#,    // "I have 3 sons"
            #"their\s+names?\s+(?:are|is)"#,            // "their names are"
            #"(?:named?|called)"#,                       // "named" / "called"
            #"(?:yes|yeah|yep|sure)[,.]?\s*"#,           // "yes, ..."
            #"(?:don'?t|didn'?t|doesn'?t)\s+know\b.*"#, // "don't know their names"
            #"(?:I\s+)?(?:can'?t|couldn'?t)\s+remember\b.*"#, // "can't remember"
            #"(?:not\s+sure|no\s+idea)\b.*"#,            // "not sure", "no idea"
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

        // Normalize "Name, 25" → "Name 25" so age stays with the name.
        // Match: comma followed by optional space and 1-3 digits (not followed by more word chars)
        if let ageCommaRegex = try? NSRegularExpression(pattern: #",\s*(\d{1,3})(?:\s*(?:,|$))"#) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = ageCommaRegex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: " $1,")
        }

        return cleaned
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { looksLikeName($0) }
    }

    /// Returns true if the string looks like a person's name (may include age/nickname).
    private func looksLikeName(_ text: String?) -> Bool {
        guard var text = text, !text.isEmpty else { return false }
        // Strip quotes and trailing numbers before checking
        text = text.replacingOccurrences(of: #"["'\u{201c}\u{201d}]"#, with: "", options: .regularExpression)
        // Remove trailing age
        if let regex = try? NSRegularExpression(pattern: #"\s*\d{1,3}\s*$"#) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard words.count >= 1 && words.count <= 5 else { return false }
        if text.contains("?") || text.contains("!") { return false }
        let nameChars = CharacterSet.letters.union(CharacterSet(charactersIn: "-'"))
        for word in words {
            if word.unicodeScalars.contains(where: { !nameChars.contains($0) }) { return false }
        }
        // Reject common non-name words (check each word)
        let stopWords: Set<String> = ["no", "nope", "none", "skip", "done", "yes", "yeah", "yep",
                                       "my", "the", "from", "with", "don't", "dont", "have", "had",
                                       "was", "their", "them", "they", "know", "names", "name",
                                       "think", "about", "not", "sure", "maybe", "some", "who",
                                       "what", "when", "where", "how", "just", "also", "too",
                                       "really", "actually", "well", "like", "that", "this",
                                       "are", "were", "been", "being", "but", "for", "its"]
        // Single stop word → reject
        if words.count == 1 && stopWords.contains(words[0].lowercased()) { return false }
        // If ALL words are stop words → reject (e.g., "their names")
        if words.allSatisfy({ stopWords.contains($0.lowercased()) }) { return false }
        return true
    }

    private func isNegativeOrEmpty(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let negatives: Set<String> = ["no", "nope", "none", "skip", "no thanks", "not really", "nah"]
        return trimmed.isEmpty || negatives.contains(trimmed)
    }

    private func isDonePhrase(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let donePhrases: Set<String> = ["done", "that's it", "that's all", "i'm done", "im done",
                                         "all done", "finished", "that is all", "nothing else",
                                         "no more", "we're done", "thats all", "thats it"]
        return donePhrases.contains(lower) || lower.hasPrefix("i'm done") || lower.hasPrefix("no one else")
    }

    /// Parse a full name entry that may include nickname in quotes and age.
    /// E.g., "Bill \"Poobah\" Donner, 72" or "Bill 'Poobah' Donner 72"
    private struct ParsedNameEntry {
        let firstName: String
        let middleName: String?
        let lastName: String?
        let nickname: String?
        let age: Int?
    }

    private func parseFullNameEntry(_ input: String) -> ParsedNameEntry {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract nickname in quotes (double or single)
        var nickname: String?
        let nicknamePatterns = [#""([^"]+)""#, #"'([^']+)'"#, #"\u{201c}([^\u{201d}]+)\u{201d}"#]
        for pattern in nicknamePatterns {
            if let match = firstMatch(pattern: pattern, in: text) {
                nickname = match[1]
                text = text.replacingOccurrences(of: match[0], with: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Extract trailing age (1-3 digit number at end, possibly after comma)
        var age: Int?
        let agePattern = #"[,\s]+(\d{1,3})\s*$"#
        if let match = firstMatch(pattern: agePattern, in: text), let parsed = Int(match[1]), parsed < 150 {
            age = parsed
            text = text.replacingOccurrences(of: match[0], with: "").trimmingCharacters(in: .whitespaces)
        }

        let parts = splitName(text)
        return ParsedNameEntry(firstName: parts.first, middleName: parts.middle,
                               lastName: parts.last, nickname: nickname, age: age)
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
        nickname: String? = nil,
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
        {"firstName": "\(fn)", "middleName": \(mn.map { #""\#($0)""# } ?? "null"), "lastName": \(ln.map { #""\#($0)""# } ?? "null"), "nickname": \(nickname.map { #""\#($0)""# } ?? "null"), "birthYear": \(birthYear.map(String.init) ?? "null"), "birthPlace": null, "isLiving": \(isLiving.map { $0 ? "true" : "false" } ?? "true"), "deathYear": null, "gender": \(gender.map { #""\#($0)""# } ?? "null"), "relationships": [\(relsJSON)], "isComplete": true}
        ```
        """
    }
}
