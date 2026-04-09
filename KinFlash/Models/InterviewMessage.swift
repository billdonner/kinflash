import Foundation
import GRDB

struct PersistedMessage: Codable, Sendable, Identifiable {
    var id: UUID
    var role: String       // "system", "user", "assistant"
    var content: String
    var createdAt: Date
}

extension PersistedMessage: FetchableRecord, PersistableRecord {
    static let databaseTableName = "interviewMessage"
}
