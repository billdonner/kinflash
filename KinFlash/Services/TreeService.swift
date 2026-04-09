import Foundation
import GRDB

enum TreeServiceError: Error, LocalizedError {
    case selfRelationship
    case duplicateRelationship
    case circularParentChain
    case personNotFound
    case invalidDates

    var errorDescription: String? {
        switch self {
        case .selfRelationship: "Cannot create a relationship with oneself"
        case .duplicateRelationship: "This relationship already exists"
        case .circularParentChain: "This would create a circular parent chain"
        case .personNotFound: "Person not found"
        case .invalidDates: "Birth date must be before death date"
        }
    }
}

struct TreeService: Sendable {
    let dbQueue: DatabaseQueue

    // MARK: - Person CRUD

    func addPerson(_ person: Person) throws {
        var p = person
        if let birth = p.birthDate, let death = p.deathDate, birth >= death {
            throw TreeServiceError.invalidDates
        }
        p.createdAt = Date()
        p.updatedAt = Date()
        try dbQueue.write { db in
            try p.insert(db)
        }
    }

    func updatePerson(_ person: Person) throws {
        var p = person
        if let birth = p.birthDate, let death = p.deathDate, birth >= death {
            throw TreeServiceError.invalidDates
        }
        p.updatedAt = Date()
        try dbQueue.write { db in
            try p.update(db)
        }
    }

    func deletePerson(id: UUID) throws {
        try dbQueue.write { db in
            _ = try Person.deleteOne(db, key: id)
        }
    }

    func fetchPerson(id: UUID) throws -> Person? {
        try dbQueue.read { db in
            try Person.fetchOne(db, key: id)
        }
    }

    func fetchAllPeople() throws -> [Person] {
        try dbQueue.read { db in
            try Person.order(Column("lastName"), Column("firstName")).fetchAll(db)
        }
    }

    // MARK: - Relationship CRUD

    func addRelationship(from fromId: UUID, to toId: UUID, type: RelationshipType, subtype: RelationshipSubtype? = nil, startDate: Date? = nil) throws {
        guard fromId != toId else {
            throw TreeServiceError.selfRelationship
        }

        try dbQueue.write { db in
            // Check both people exist
            guard try Person.fetchOne(db, key: fromId) != nil,
                  try Person.fetchOne(db, key: toId) != nil else {
                throw TreeServiceError.personNotFound
            }

            // Check for duplicate — use GRDB's native UUID encoding via Column filter
            let existing = try Relationship
                .filter(Column("fromPersonId") == fromId && Column("toPersonId") == toId && Column("type") == type.rawValue)
                .fetchOne(db)
            if existing != nil {
                throw TreeServiceError.duplicateRelationship
            }

            // For parent relationships, check for cycles
            if type == .parent {
                let hasCycle = try detectParentCycle(db: db, parentId: fromId, childId: toId)
                if hasCycle {
                    throw TreeServiceError.circularParentChain
                }
            }

            let now = Date()

            // Insert the primary relationship
            let rel = Relationship(
                id: UUID(), fromPersonId: fromId, toPersonId: toId,
                type: type, subtype: subtype, startDate: startDate,
                endDate: nil, createdAt: now
            )
            try rel.insert(db)

            // For bidirectional types, insert the reverse
            if type == .spouse || type == .sibling {
                let reverseExists = try Relationship
                    .filter(Column("fromPersonId") == toId && Column("toPersonId") == fromId && Column("type") == type.rawValue)
                    .fetchOne(db)
                if reverseExists == nil {
                    let reverse = Relationship(
                        id: UUID(), fromPersonId: toId, toPersonId: fromId,
                        type: type, subtype: subtype, startDate: startDate,
                        endDate: nil, createdAt: now
                    )
                    try reverse.insert(db)
                }
            }
        }
    }

    func removeRelationship(id: UUID) throws {
        try dbQueue.write { db in
            _ = try Relationship.deleteOne(db, key: id)
        }
    }

    func fetchRelationships(for personId: UUID) throws -> [Relationship] {
        try dbQueue.read { db in
            try Relationship
                .filter(Column("fromPersonId") == personId || Column("toPersonId") == personId)
                .fetchAll(db)
        }
    }

    func fetchOutgoing(for personId: UUID) throws -> [Relationship] {
        try dbQueue.read { db in
            try Relationship
                .filter(Column("fromPersonId") == personId)
                .fetchAll(db)
        }
    }

    // MARK: - Cycle Detection

    /// Returns true if making `parentId` a parent of `childId` would create a cycle.
    /// A cycle exists if `childId` is already an ancestor of `parentId`.
    private func detectParentCycle(db: Database, parentId: UUID, childId: UUID) throws -> Bool {
        var visited = Set<UUID>()
        var queue = [parentId]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current == childId { return true }
            if visited.contains(current) { continue }
            visited.insert(current)

            // Walk UP: find parents of current
            // fromPersonId IS PARENT OF toPersonId
            // So to find parents of `current`, find rows where toPersonId == current
            let parents = try Relationship
                .filter(Column("toPersonId") == current && Column("type") == RelationshipType.parent.rawValue)
                .fetchAll(db)
            for rel in parents {
                queue.append(rel.fromPersonId)
            }
        }
        return false
    }
}
