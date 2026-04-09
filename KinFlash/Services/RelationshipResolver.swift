import Foundation
import GRDB

/// Direction-aware edge for BFS traversal
enum TraversalEdge: String, Sendable {
    case parent   // walking UP to a parent
    case child    // walking DOWN to a child
    case spouse
    case sibling
}

struct RelationshipLabel: Sendable, Equatable {
    let label: String
    let chain: [TraversalEdge]

    var chainDescription: String {
        chain.map(\.rawValue).joined(separator: " → ")
    }
}

struct RelationshipResolver: Sendable {
    let dbQueue: DatabaseQueue

    // MARK: - Public API

    /// Resolve the colloquial relationship label from `fromId`'s perspective to `toId`.
    func resolve(from fromId: UUID, to toId: UUID) throws -> RelationshipLabel? {
        guard fromId != toId else { return nil }
        let allEdges = try loadAllEdges()
        return bfsResolve(from: fromId, to: toId, allEdges: allEdges, maxHops: 4)
    }

    /// Resolve labels for ALL reachable people from `fromId` within `maxHops`.
    func resolveAll(from fromId: UUID, maxHops: Int = 4) throws -> [UUID: RelationshipLabel] {
        let allEdges = try loadAllEdges()
        return bfsResolveAll(from: fromId, allEdges: allEdges, maxHops: maxHops)
    }

    // MARK: - Edge Loading

    /// Builds a traversal-friendly adjacency list from the raw relationship table.
    /// For each stored relationship, we create directed traversal edges:
    ///   .parent (A is parent of B) → from B: edge .parent to A; from A: edge .child to B
    ///   .spouse → from A: edge .spouse to B (reverse already stored as separate row)
    ///   .sibling → from A: edge .sibling to B (reverse already stored as separate row)
    private func loadAllEdges() throws -> [UUID: [(TraversalEdge, UUID, RelationshipSubtype?)]] {
        let relationships = try dbQueue.read { db in
            try Relationship.fetchAll(db)
        }

        var adjacency: [UUID: [(TraversalEdge, UUID, RelationshipSubtype?)]] = [:]

        for rel in relationships {
            switch rel.type {
            case .parent:
                // rel.fromPersonId IS PARENT OF rel.toPersonId
                // From child's perspective: walk up to parent
                adjacency[rel.toPersonId, default: []].append((.parent, rel.fromPersonId, rel.subtype))
                // From parent's perspective: walk down to child
                adjacency[rel.fromPersonId, default: []].append((.child, rel.toPersonId, rel.subtype))

            case .spouse:
                // Already stored as two rows, but we read from fromPersonId side
                adjacency[rel.fromPersonId, default: []].append((.spouse, rel.toPersonId, rel.subtype))

            case .sibling:
                // Already stored as two rows
                adjacency[rel.fromPersonId, default: []].append((.sibling, rel.toPersonId, rel.subtype))
            }
        }

        return adjacency
    }

    // MARK: - BFS

    private struct BFSNode {
        let personId: UUID
        let path: [(TraversalEdge, RelationshipSubtype?)]
    }

    private func bfsResolve(from fromId: UUID, to toId: UUID, allEdges: [UUID: [(TraversalEdge, UUID, RelationshipSubtype?)]], maxHops: Int) -> RelationshipLabel? {
        var visited = Set<UUID>([fromId])
        var queue: [BFSNode] = [BFSNode(personId: fromId, path: [])]

        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node.path.count >= maxHops { continue }

            let edges = allEdges[node.personId] ?? []
            for (edgeType, nextId, subtype) in edges {
                if nextId == toId {
                    let fullPath = node.path + [(edgeType, subtype)]
                    return computeLabel(path: fullPath, targetId: toId)
                }
                if !visited.contains(nextId) {
                    visited.insert(nextId)
                    let newPath = node.path + [(edgeType, subtype)]
                    queue.append(BFSNode(personId: nextId, path: newPath))
                }
            }
        }

        return nil
    }

    private func bfsResolveAll(from fromId: UUID, allEdges: [UUID: [(TraversalEdge, UUID, RelationshipSubtype?)]], maxHops: Int) -> [UUID: RelationshipLabel] {
        var visited = Set<UUID>([fromId])
        var queue: [BFSNode] = [BFSNode(personId: fromId, path: [])]
        var results: [UUID: RelationshipLabel] = [:]

        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node.path.count >= maxHops { continue }

            let edges = allEdges[node.personId] ?? []
            for (edgeType, nextId, subtype) in edges {
                if !visited.contains(nextId) {
                    visited.insert(nextId)
                    let fullPath = node.path + [(edgeType, subtype)]
                    if let label = computeLabel(path: fullPath, targetId: nextId) {
                        results[nextId] = label
                    }
                    queue.append(BFSNode(personId: nextId, path: fullPath))
                }
            }
        }

        return results
    }

    // MARK: - Label Computation

    private func computeLabel(path: [(TraversalEdge, RelationshipSubtype?)], targetId: UUID) -> RelationshipLabel? {
        let edges = path.map { $0.0 }
        let subtypes = path.map { $0.1 }

        let gender = try? dbQueue.read { db in
            try Person.fetchOne(db, key: targetId)?.gender
        }

        let hasStep = subtypes.contains(.step)
        let hasAdoptive = subtypes.contains(.adoptive)
        let hasHalf = subtypes.contains(.half)
        let prefix: String
        if hasStep { prefix = "Step-" }
        else if hasAdoptive { prefix = "Adoptive " }
        else if hasHalf { prefix = "Half-" }
        else { prefix = "" }

        let baseLabel: String

        switch edges {
        // 1-hop
        case [.parent]:
            baseLabel = gendered(gender, m: "Father", f: "Mother", n: "Parent")
        case [.child]:
            baseLabel = gendered(gender, m: "Son", f: "Daughter", n: "Child")
        case [.spouse]:
            baseLabel = gendered(gender, m: "Husband", f: "Wife", n: "Spouse")
        case [.sibling]:
            baseLabel = gendered(gender, m: "Brother", f: "Sister", n: "Sibling")

        // 2-hop
        case [.parent, .parent]:
            baseLabel = gendered(gender, m: "Grandfather", f: "Grandmother", n: "Grandparent")
        case [.child, .child]:
            baseLabel = gendered(gender, m: "Grandson", f: "Granddaughter", n: "Grandchild")
        case [.parent, .sibling]:
            baseLabel = gendered(gender, m: "Uncle", f: "Aunt", n: "Parent's Sibling")
        case [.sibling, .child]:
            baseLabel = gendered(gender, m: "Nephew", f: "Niece", n: "Sibling's Child")
        case [.spouse, .parent]:
            baseLabel = gendered(gender, m: "Father-in-law", f: "Mother-in-law", n: "Parent-in-law")
        case [.child, .spouse]:
            baseLabel = gendered(gender, m: "Son-in-law", f: "Daughter-in-law", n: "Child-in-law")
        case [.parent, .spouse]:
            // Parent's spouse who is not your parent = stepparent
            baseLabel = gendered(gender, m: "Stepfather", f: "Stepmother", n: "Step-parent")
        case [.spouse, .child]:
            // Spouse's child who is not your child = stepchild
            baseLabel = gendered(gender, m: "Stepson", f: "Stepdaughter", n: "Stepchild")
        case [.spouse, .sibling]:
            baseLabel = gendered(gender, m: "Brother-in-law", f: "Sister-in-law", n: "Sibling-in-law")
        case [.sibling, .spouse]:
            baseLabel = gendered(gender, m: "Brother-in-law", f: "Sister-in-law", n: "Sibling-in-law")

        // 3-hop
        case [.parent, .parent, .parent]:
            baseLabel = gendered(gender, m: "Great-Grandfather", f: "Great-Grandmother", n: "Great-Grandparent")
        case [.child, .child, .child]:
            baseLabel = gendered(gender, m: "Great-Grandson", f: "Great-Granddaughter", n: "Great-Grandchild")
        case [.parent, .sibling, .child]:
            baseLabel = "First Cousin"
        case [.parent, .parent, .sibling]:
            baseLabel = gendered(gender, m: "Great-Uncle", f: "Great-Aunt", n: "Grandparent's Sibling")
        case [.sibling, .child, .child]:
            baseLabel = gendered(gender, m: "Grand-Nephew", f: "Grand-Niece", n: "Sibling's Grandchild")
        case [.spouse, .parent, .parent]:
            baseLabel = gendered(gender, m: "Grandfather-in-law", f: "Grandmother-in-law", n: "Grandparent-in-law")
        case [.spouse, .sibling, .child]:
            baseLabel = "Spouse's Nephew/Niece"

        // 4-hop
        case [.parent, .parent, .parent, .parent]:
            baseLabel = gendered(gender, m: "Great-Great-Grandfather", f: "Great-Great-Grandmother", n: "Great-Great-Grandparent")
        case [.parent, .parent, .sibling, .child]:
            baseLabel = "First Cousin Once Removed"
        case [.parent, .sibling, .child, .child]:
            baseLabel = "First Cousin's Child"

        default:
            baseLabel = "Distant Relative"
        }

        // Don't double-prefix for step-parent/child paths already labelled as step
        let finalLabel: String
        if prefix.isEmpty || baseLabel.lowercased().hasPrefix("step") || baseLabel == "Distant Relative" || baseLabel == "First Cousin" || baseLabel == "First Cousin Once Removed" || baseLabel == "First Cousin's Child" {
            finalLabel = baseLabel
        } else {
            finalLabel = "\(prefix)\(baseLabel.lowercased())"
        }

        return RelationshipLabel(label: finalLabel, chain: edges)
    }

    private func gendered(_ gender: Gender??, m: String, f: String, n: String) -> String {
        switch gender {
        case .some(.some(.male)): return m
        case .some(.some(.female)): return f
        default: return n
        }
    }
}
