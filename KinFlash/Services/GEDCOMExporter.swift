import Foundation
import GRDB

struct GEDCOMExporter: Sendable {
    let dbQueue: DatabaseQueue

    func export() throws -> String {
        try dbQueue.read { db in
            let people = try Person.fetchAll(db)
            let relationships = try Relationship.fetchAll(db)

            var output = ""
            output += "0 HEAD\n"
            output += "1 SOUR KinFlash\n"
            output += "1 GEDC\n"
            output += "2 VERS 5.5.1\n"

            // Assign GEDCOM IDs
            var personToGedcom: [UUID: String] = [:]
            for (index, person) in people.enumerated() {
                let gedcomId = person.gedcomId ?? "@I\(index + 1)@"
                personToGedcom[person.id] = gedcomId
            }

            // Write INDI records
            for person in people {
                guard let gedcomId = personToGedcom[person.id] else { continue }
                output += "0 \(gedcomId) INDI\n"

                let lastName = person.lastName ?? ""
                let firstName = [person.firstName, person.middleName].compactMap { $0 }.joined(separator: " ")
                output += "1 NAME \(firstName) /\(lastName)/\n"

                if let gender = person.gender {
                    switch gender {
                    case .male: output += "1 SEX M\n"
                    case .female: output += "1 SEX F\n"
                    default: break
                    }
                }

                if let birthDate = person.birthDate {
                    output += "1 BIRT\n"
                    output += "2 DATE \(formatGEDCOMDate(birthDate))\n"
                    if let place = person.birthPlace {
                        output += "2 PLAC \(place)\n"
                    }
                } else if let birthYear = person.birthYear {
                    output += "1 BIRT\n"
                    output += "2 DATE \(birthYear)\n"
                    if let place = person.birthPlace {
                        output += "2 PLAC \(place)\n"
                    }
                }

                if let deathDate = person.deathDate {
                    output += "1 DEAT\n"
                    output += "2 DATE \(formatGEDCOMDate(deathDate))\n"
                } else if let deathYear = person.deathYear {
                    output += "1 DEAT\n"
                    output += "2 DATE \(deathYear)\n"
                }

                if let notes = person.notes, !notes.isEmpty {
                    output += "1 NOTE \(notes)\n"
                }
            }

            // Build FAM records from spouse + parent relationships
            var familyGroups: [String: GEDCOMFamilyGroup] = [:] // key: sorted spouse pair or single parent

            // Group by spouse pairs
            let spouseRels = relationships.filter { $0.type == .spouse }
            var processedSpousePairs = Set<String>()

            for rel in spouseRels {
                let key = [rel.fromPersonId.uuidString, rel.toPersonId.uuidString].sorted().joined(separator: "-")
                guard !processedSpousePairs.contains(key) else { continue }
                processedSpousePairs.insert(key)

                let famId = "@F\(familyGroups.count + 1)@"
                var group = GEDCOMFamilyGroup()

                // Determine husband/wife by gender
                let person1 = try Person.fetchOne(db, key: rel.fromPersonId)
                let person2 = try Person.fetchOne(db, key: rel.toPersonId)

                if person1?.gender == .male {
                    group.husbandId = personToGedcom[rel.fromPersonId]
                    group.wifeId = personToGedcom[rel.toPersonId]
                } else {
                    group.husbandId = personToGedcom[rel.toPersonId]
                    group.wifeId = personToGedcom[rel.fromPersonId]
                }

                // Find children of this couple
                let parentRels1 = relationships.filter { $0.fromPersonId == rel.fromPersonId && $0.type == .parent }
                let parentRels2 = relationships.filter { $0.fromPersonId == rel.toPersonId && $0.type == .parent }
                let children1 = Set(parentRels1.map(\.toPersonId))
                let children2 = Set(parentRels2.map(\.toPersonId))
                let sharedChildren = children1.intersection(children2)

                group.childIds = sharedChildren.compactMap { personToGedcom[$0] }
                familyGroups[famId] = group
            }

            // Write FAM records
            for (famId, group) in familyGroups.sorted(by: { $0.key < $1.key }) {
                output += "0 \(famId) FAM\n"
                if let h = group.husbandId { output += "1 HUSB \(h)\n" }
                if let w = group.wifeId { output += "1 WIFE \(w)\n" }
                for childId in group.childIds {
                    output += "1 CHIL \(childId)\n"
                }
            }

            output += "0 TRLR\n"
            return output
        }
    }

    private func formatGEDCOMDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date).uppercased()
    }
}

private struct GEDCOMFamilyGroup {
    var husbandId: String?
    var wifeId: String?
    var childIds: [String] = []
}
