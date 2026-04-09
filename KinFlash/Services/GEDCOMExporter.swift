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

            // Build family groups from ALL parent-child relationships, not just spouse pairs
            var familyGroups: [String: MutableFamilyGroup] = [:]
            var childToFamily: [UUID: String] = [:]  // child → family key
            var processedSpousePairs = Set<String>()

            // Step 1: Create family groups from spouse pairs
            let spouseRels = relationships.filter { $0.type == .spouse }
            for rel in spouseRels {
                let key = [rel.fromPersonId.uuidString, rel.toPersonId.uuidString].sorted().joined(separator: "-")
                guard !processedSpousePairs.contains(key) else { continue }
                processedSpousePairs.insert(key)

                let famId = "@F\(familyGroups.count + 1)@"
                var group = MutableFamilyGroup()

                let person1 = try Person.fetchOne(db, key: rel.fromPersonId)
                let person2 = try Person.fetchOne(db, key: rel.toPersonId)

                if person1?.gender == .male {
                    group.husbandUUID = rel.fromPersonId
                    group.wifeUUID = rel.toPersonId
                } else if person2?.gender == .male {
                    group.husbandUUID = rel.toPersonId
                    group.wifeUUID = rel.fromPersonId
                } else {
                    group.husbandUUID = rel.fromPersonId
                    group.wifeUUID = rel.toPersonId
                }

                familyGroups[famId] = group
            }

            // Step 2: Assign children to families
            let parentRels = relationships.filter { $0.type == .parent }

            // Group parent relationships by child
            var childParents: [UUID: Set<UUID>] = [:]
            for rel in parentRels {
                childParents[rel.toPersonId, default: []].insert(rel.fromPersonId)
            }

            for (childId, parents) in childParents {
                // Find the family whose parents exactly match this child's parents.
                // For a child with 2 known parents, the family must have both.
                // For a child with 1 known parent, prefer a family where that parent
                // appears AND the child has no second known parent (avoid wrong family
                // in multi-spouse scenarios).
                var assignedFamily: String?
                var bestMatchScore = 0

                for (famId, group) in familyGroups {
                    let famParents = Set([group.husbandUUID, group.wifeUUID].compactMap { $0 })
                    guard !famParents.isEmpty else { continue }

                    // Exact match: child's parents == family's parents
                    if parents == famParents {
                        assignedFamily = famId
                        break
                    }

                    // Partial match: all of child's parents are in this family,
                    // and the match score is higher than any previous candidate
                    let overlap = parents.intersection(famParents).count
                    if overlap == parents.count && overlap > bestMatchScore {
                        bestMatchScore = overlap
                        assignedFamily = famId
                    }
                }

                if let famId = assignedFamily {
                    familyGroups[famId]?.childUUIDs.append(childId)
                    childToFamily[childId] = famId
                } else {
                    // No matching family — create a new one for single-parent or unmatched cases
                    let famId = "@F\(familyGroups.count + 1)@"
                    var group = MutableFamilyGroup()

                    for parentId in parents {
                        let parent = try Person.fetchOne(db, key: parentId)
                        if parent?.gender == .male && group.husbandUUID == nil {
                            group.husbandUUID = parentId
                        } else if group.wifeUUID == nil {
                            group.wifeUUID = parentId
                        } else if group.husbandUUID == nil {
                            group.husbandUUID = parentId
                        }
                    }

                    group.childUUIDs.append(childId)
                    familyGroups[famId] = group
                    childToFamily[childId] = famId
                }
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

                // FAMC — families where this person is a child
                if let famId = childToFamily[person.id] {
                    output += "1 FAMC \(famId)\n"
                }

                // FAMS — families where this person is a spouse/parent
                for (famId, group) in familyGroups {
                    if group.husbandUUID == person.id || group.wifeUUID == person.id {
                        output += "1 FAMS \(famId)\n"
                    }
                }
            }

            // Write FAM records
            for (famId, group) in familyGroups.sorted(by: { $0.key < $1.key }) {
                output += "0 \(famId) FAM\n"
                if let h = group.husbandUUID, let gid = personToGedcom[h] { output += "1 HUSB \(gid)\n" }
                if let w = group.wifeUUID, let gid = personToGedcom[w] { output += "1 WIFE \(gid)\n" }
                for childUUID in group.childUUIDs {
                    if let gid = personToGedcom[childUUID] {
                        output += "1 CHIL \(gid)\n"
                    }
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

private struct MutableFamilyGroup {
    var husbandUUID: UUID?
    var wifeUUID: UUID?
    var childUUIDs: [UUID] = []
}
