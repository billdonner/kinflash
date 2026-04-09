import Foundation
import GRDB

enum RelationshipType: String, Codable, Sendable, DatabaseValueConvertible {
    case parent
    case spouse
    case sibling
}

enum RelationshipSubtype: String, Codable, Sendable, DatabaseValueConvertible {
    case biological
    case step
    case adoptive
    case half
}

struct Relationship: Codable, Sendable, Identifiable {
    var id: UUID
    var fromPersonId: UUID
    var toPersonId: UUID
    var type: RelationshipType
    var subtype: RelationshipSubtype?
    var startDate: Date?
    var endDate: Date?
    var createdAt: Date
}

extension Relationship: FetchableRecord, PersistableRecord {
    static let databaseTableName = "relationship"
}
