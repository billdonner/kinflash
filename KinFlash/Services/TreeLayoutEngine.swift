import Foundation
import GRDB

/// Position of a person node in the visual tree.
struct NodePosition: Sendable, Equatable {
    let personId: UUID
    let generation: Int   // 0 = root, negative = ancestors, positive = descendants
    let x: CGFloat
    let y: CGFloat
}

/// Connection line between two nodes.
struct TreeConnection: Sendable {
    let fromId: UUID
    let toId: UUID
    let type: RelationshipType
}

/// Complete layout result for rendering.
struct TreeLayout: Sendable {
    let nodes: [NodePosition]
    let connections: [TreeConnection]
    let totalSize: CGSize
}

struct TreeLayoutEngine: Sendable {
    let dbQueue: DatabaseQueue

    // Layout constants
    let nodeWidth: CGFloat = 120
    let nodeHeight: CGFloat = 80
    let horizontalSpacing: CGFloat = 40
    let verticalSpacing: CGFloat = 120

    /// Compute layout starting from a root person.
    func computeLayout(rootPersonId: UUID) throws -> TreeLayout {
        let people = try dbQueue.read { db in try Person.fetchAll(db) }
        let relationships = try dbQueue.read { db in try Relationship.fetchAll(db) }

        let personMap = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })

        // Build adjacency
        var parentOf: [UUID: [UUID]] = [:]  // parent → [children]
        var childOf: [UUID: [UUID]] = [:]   // child → [parents]
        var spouseOf: [UUID: [UUID]] = [:]  // person → [spouses]

        for rel in relationships {
            switch rel.type {
            case .parent:
                parentOf[rel.fromPersonId, default: []].append(rel.toPersonId)
                childOf[rel.toPersonId, default: []].append(rel.fromPersonId)
            case .spouse:
                spouseOf[rel.fromPersonId, default: []].append(rel.toPersonId)
            case .sibling:
                break // derived from parent-child
            }
        }

        // Assign generations via BFS from root
        var generationMap: [UUID: Int] = [rootPersonId: 0]
        var queue: [UUID] = [rootPersonId]
        var visited = Set<UUID>([rootPersonId])

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let gen = generationMap[current]!

            // Parents are one generation up (negative)
            for parentId in (childOf[current] ?? []) {
                if !visited.contains(parentId) {
                    visited.insert(parentId)
                    generationMap[parentId] = gen - 1
                    queue.append(parentId)
                }
            }

            // Children are one generation down (positive)
            for childId in (parentOf[current] ?? []) {
                if !visited.contains(childId) {
                    visited.insert(childId)
                    generationMap[childId] = gen + 1
                    queue.append(childId)
                }
            }

            // Spouses are same generation
            for spouseId in (spouseOf[current] ?? []) {
                if !visited.contains(spouseId) {
                    visited.insert(spouseId)
                    generationMap[spouseId] = gen
                    queue.append(spouseId)
                }
            }
        }

        // Group by generation
        var generationGroups: [Int: [UUID]] = [:]
        for (personId, gen) in generationMap {
            generationGroups[gen, default: []].append(personId)
        }

        // Sort generations
        let sortedGens = generationGroups.keys.sorted()
        guard !sortedGens.isEmpty else {
            return TreeLayout(nodes: [], connections: [], totalSize: .zero)
        }

        // Normalize generation indices to start at 0
        let minGen = sortedGens.first!

        // Position nodes
        var nodes: [NodePosition] = []
        let totalWidth = nodeWidth + horizontalSpacing

        for gen in sortedGens {
            let members = generationGroups[gen]!

            // Order: place spouses adjacent to each other
            let ordered = orderWithinGeneration(members: members, spouseOf: spouseOf)

            let rowY = CGFloat(gen - minGen) * (nodeHeight + verticalSpacing)

            // Center the row
            let rowWidth = CGFloat(ordered.count) * totalWidth - horizontalSpacing
            let startX = -rowWidth / 2

            for (index, personId) in ordered.enumerated() {
                let x = startX + CGFloat(index) * totalWidth + nodeWidth / 2
                nodes.append(NodePosition(
                    personId: personId,
                    generation: gen,
                    x: x,
                    y: rowY
                ))
            }
        }

        // Build connections
        var connections: [TreeConnection] = []
        var processedPairs = Set<String>()

        for rel in relationships {
            guard generationMap[rel.fromPersonId] != nil,
                  generationMap[rel.toPersonId] != nil else { continue }

            let key = [rel.fromPersonId.uuidString, rel.toPersonId.uuidString].sorted().joined(separator: "-")
            if processedPairs.contains(key) { continue }
            processedPairs.insert(key)

            connections.append(TreeConnection(
                fromId: rel.fromPersonId,
                toId: rel.toPersonId,
                type: rel.type
            ))
        }

        // Compute total size
        let allX = nodes.map(\.x)
        let allY = nodes.map(\.y)
        let minX = (allX.min() ?? 0) - nodeWidth / 2
        let maxX = (allX.max() ?? 0) + nodeWidth / 2
        let maxY = (allY.max() ?? 0) + nodeHeight

        let totalSize = CGSize(
            width: maxX - minX + horizontalSpacing * 2,
            height: maxY + verticalSpacing
        )

        return TreeLayout(nodes: nodes, connections: connections, totalSize: totalSize)
    }

    /// Order members within a generation, placing spouses adjacent.
    private func orderWithinGeneration(members: [UUID], spouseOf: [UUID: [UUID]]) -> [UUID] {
        var ordered: [UUID] = []
        var placed = Set<UUID>()

        for member in members {
            if placed.contains(member) { continue }
            ordered.append(member)
            placed.insert(member)

            // Place spouses right next to this person
            for spouse in (spouseOf[member] ?? []) {
                if members.contains(spouse) && !placed.contains(spouse) {
                    ordered.append(spouse)
                    placed.insert(spouse)
                }
            }
        }

        return ordered
    }
}
