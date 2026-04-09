import Foundation
import GRDB

struct AppSettings: Codable, Sendable, Identifiable {
    var id: Int = 1
    var rootPersonId: UUID?
    var hasCompletedOnboarding: Bool
    var selectedAIProvider: String?
    var selectedModel: String?
    var createdAt: Date
    var updatedAt: Date
}

extension AppSettings: FetchableRecord, PersistableRecord {
    static let databaseTableName = "appSettings"

    static func current(_ db: Database) throws -> AppSettings {
        try AppSettings.fetchOne(db, key: 1) ?? AppSettings(
            hasCompletedOnboarding: false,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
