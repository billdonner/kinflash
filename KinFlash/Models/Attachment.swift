import Foundation
import GRDB

enum AttachmentType: String, Codable, Sendable, DatabaseValueConvertible {
    case photo
    case document
}

struct Attachment: Codable, Sendable, Identifiable {
    var id: UUID
    var personId: UUID
    var type: AttachmentType
    var filename: String
    var label: String?
    var createdAt: Date
    var updatedAt: Date
}

extension Attachment: FetchableRecord, PersistableRecord {
    static let databaseTableName = "attachment"
}
