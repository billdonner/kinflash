import Foundation
import GRDB

struct GEDCOMParseResult: Sendable {
    let people: [Person]
    let relationships: [Relationship]
    let errors: [GEDCOMParseError]
    var importedCount: Int { people.count }
    var errorCount: Int { errors.count }
}

struct GEDCOMParseError: Sendable {
    let line: Int
    let message: String
}

struct GEDCOMParser: Sendable {

    func parse(content: String) -> GEDCOMParseResult {
        let lines = content.components(separatedBy: .newlines)
        var individuals: [String: GEDCOMIndividual] = [:] // gedcomId → individual
        var families: [String: GEDCOMFamily] = [:]         // gedcomId → family
        var errors: [GEDCOMParseError] = []

        var currentEntity: String? // "@I1@" etc.
        var currentType: EntityType?
        var currentSubTag: String?

        enum EntityType { case individual, family }

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            let parts = line.components(separatedBy: " ")
            guard let level = Int(parts[0]) else {
                errors.append(GEDCOMParseError(line: lineIndex + 1, message: "Invalid level: \(parts[0])"))
                continue
            }

            if level == 0 {
                currentSubTag = nil
                if parts.count >= 3 {
                    let id = parts[1]
                    let tag = parts[2]
                    if tag == "INDI" {
                        currentEntity = id
                        currentType = .individual
                        individuals[id] = GEDCOMIndividual(gedcomId: id)
                    } else if tag == "FAM" {
                        currentEntity = id
                        currentType = .family
                        families[id] = GEDCOMFamily(gedcomId: id)
                    } else {
                        currentEntity = nil
                        currentType = nil
                    }
                } else {
                    let tag = parts.count > 1 ? parts[1] : ""
                    if tag == "HEAD" || tag == "TRLR" {
                        currentEntity = nil
                        currentType = nil
                    }
                }
                continue
            }

            guard let entity = currentEntity else { continue }
            let tag = parts.count > 1 ? parts[1] : ""
            let value = parts.count > 2 ? parts[2...].joined(separator: " ") : ""

            if level == 1 {
                currentSubTag = tag

                switch currentType {
                case .individual:
                    switch tag {
                    case "NAME":
                        let parsed = parseName(value)
                        individuals[entity]?.firstName = parsed.first
                        individuals[entity]?.lastName = parsed.last
                    case "SEX":
                        individuals[entity]?.sex = value
                    case "BIRT", "DEAT":
                        break // handled at level 2
                    case "FAMC":
                        individuals[entity]?.familyChild = value
                    case "FAMS":
                        individuals[entity]?.familySpouse.append(value)
                    default:
                        break
                    }

                case .family:
                    switch tag {
                    case "HUSB":
                        families[entity]?.husbandId = value
                    case "WIFE":
                        families[entity]?.wifeId = value
                    case "CHIL":
                        families[entity]?.childIds.append(value)
                    default:
                        break
                    }

                case nil:
                    break
                }
            }

            if level == 2 && currentType == .individual {
                switch (currentSubTag, tag) {
                case ("BIRT", "DATE"):
                    individuals[entity]?.birthDateString = value
                case ("BIRT", "PLAC"):
                    individuals[entity]?.birthPlace = value
                case ("DEAT", "DATE"):
                    individuals[entity]?.deathDateString = value
                    individuals[entity]?.isLiving = false
                default:
                    break
                }
            }
        }

        // Convert to domain models
        var people: [Person] = []
        var gedcomToUUID: [String: UUID] = [:]

        for (gedcomId, indi) in individuals {
            let uuid = UUID()
            gedcomToUUID[gedcomId] = uuid

            let birthDate = parseGEDCOMDate(indi.birthDateString)
            let deathDate = parseGEDCOMDate(indi.deathDateString)
            let birthYear = birthDate == nil ? parseGEDCOMYear(indi.birthDateString) : nil
            let deathYear = deathDate == nil ? parseGEDCOMYear(indi.deathDateString) : nil

            let gender: Gender?
            switch indi.sex?.uppercased() {
            case "M": gender = .male
            case "F": gender = .female
            default: gender = .unknown
            }

            let person = Person(
                id: uuid,
                firstName: indi.firstName ?? "Unknown",
                middleName: nil,
                lastName: indi.lastName,
                nickname: nil,
                birthDate: birthDate,
                birthYear: birthYear,
                deathDate: deathDate,
                deathYear: deathYear,
                isLiving: indi.isLiving,
                birthPlace: indi.birthPlace,
                gender: gender,
                notes: nil,
                profilePhotoFilename: nil,
                gedcomId: gedcomId,
                createdAt: Date(),
                updatedAt: Date()
            )
            people.append(person)
        }

        // Build relationships from FAM records
        var relationships: [Relationship] = []
        let now = Date()

        for (_, family) in families {
            let husbandUUID = family.husbandId.flatMap { gedcomToUUID[$0] }
            let wifeUUID = family.wifeId.flatMap { gedcomToUUID[$0] }

            // Spouse relationship (bidirectional)
            if let h = husbandUUID, let w = wifeUUID {
                relationships.append(Relationship(
                    id: UUID(), fromPersonId: h, toPersonId: w,
                    type: .spouse, subtype: nil, startDate: nil, endDate: nil, createdAt: now
                ))
                relationships.append(Relationship(
                    id: UUID(), fromPersonId: w, toPersonId: h,
                    type: .spouse, subtype: nil, startDate: nil, endDate: nil, createdAt: now
                ))
            }

            // Parent-child relationships
            for childGedcomId in family.childIds {
                guard let childUUID = gedcomToUUID[childGedcomId] else { continue }

                if let h = husbandUUID {
                    relationships.append(Relationship(
                        id: UUID(), fromPersonId: h, toPersonId: childUUID,
                        type: .parent, subtype: .biological, startDate: nil, endDate: nil, createdAt: now
                    ))
                }
                if let w = wifeUUID {
                    relationships.append(Relationship(
                        id: UUID(), fromPersonId: w, toPersonId: childUUID,
                        type: .parent, subtype: .biological, startDate: nil, endDate: nil, createdAt: now
                    ))
                }
            }

            // Sibling relationships among children
            let childUUIDs = family.childIds.compactMap { gedcomToUUID[$0] }
            for i in 0..<childUUIDs.count {
                for j in (i + 1)..<childUUIDs.count {
                    relationships.append(Relationship(
                        id: UUID(), fromPersonId: childUUIDs[i], toPersonId: childUUIDs[j],
                        type: .sibling, subtype: .biological, startDate: nil, endDate: nil, createdAt: now
                    ))
                    relationships.append(Relationship(
                        id: UUID(), fromPersonId: childUUIDs[j], toPersonId: childUUIDs[i],
                        type: .sibling, subtype: .biological, startDate: nil, endDate: nil, createdAt: now
                    ))
                }
            }
        }

        return GEDCOMParseResult(people: people, relationships: relationships, errors: errors)
    }

    /// Import parsed results into the database
    func importToDatabase(_ result: GEDCOMParseResult, dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            for person in result.people {
                try person.insert(db)
            }
            for relationship in result.relationships {
                try relationship.insert(db)
            }
        }
    }

    // MARK: - Private Helpers

    private func parseName(_ raw: String) -> (first: String?, last: String?) {
        // GEDCOM format: "John /Smith/" or "John Robert /Smith/"
        let parts = raw.components(separatedBy: "/")
        let first = parts[0].trimmingCharacters(in: .whitespaces)
        let last = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        return (first.isEmpty ? nil : first, last?.isEmpty == true ? nil : last)
    }

    private func parseGEDCOMDate(_ dateString: String?) -> Date? {
        guard let ds = dateString, !ds.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Try full date: "12 JUN 1945"
        formatter.dateFormat = "d MMM yyyy"
        if let date = formatter.date(from: ds) { return date }
        // Try "JUN 1945"
        formatter.dateFormat = "MMM yyyy"
        if let date = formatter.date(from: ds) { return date }
        return nil
    }

    private func parseGEDCOMYear(_ dateString: String?) -> Int? {
        guard let ds = dateString, !ds.isEmpty else { return nil }
        // Extract 4-digit year
        let pattern = #"\b(\d{4})\b"#
        if let range = ds.range(of: pattern, options: .regularExpression) {
            return Int(ds[range])
        }
        return nil
    }
}

// MARK: - Internal Data Structures

private struct GEDCOMIndividual {
    let gedcomId: String
    var firstName: String?
    var lastName: String?
    var sex: String?
    var birthDateString: String?
    var birthPlace: String?
    var deathDateString: String?
    var isLiving: Bool = true
    var familyChild: String?       // FAMC — family where this person is a child
    var familySpouse: [String] = [] // FAMS — families where this person is a spouse
}

private struct GEDCOMFamily {
    let gedcomId: String
    var husbandId: String?
    var wifeId: String?
    var childIds: [String] = []
}
