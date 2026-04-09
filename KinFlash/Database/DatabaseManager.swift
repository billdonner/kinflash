import Foundation
import GRDB

final class DatabaseManager: Sendable {
    let dbQueue: DatabaseQueue

    init(inMemory: Bool = false) throws {
        if inMemory {
            dbQueue = try DatabaseQueue()
        } else {
            let url = try FileManager.default
                .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("kinflash.sqlite")
            var config = Configuration()
            config.foreignKeysEnabled = true
            dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        }
        try migrate()
    }

    // Test helper: create with an existing in-memory queue
    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "appSettings") { t in
                t.primaryKey("id", .integer)
                t.column("rootPersonId", .text)
                t.column("hasCompletedOnboarding", .boolean).notNull().defaults(to: false)
                t.column("selectedAIProvider", .text)
                t.column("selectedModel", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "person") { t in
                t.primaryKey("id", .text) // UUID stored as text
                t.column("firstName", .text).notNull()
                t.column("middleName", .text)
                t.column("lastName", .text)
                t.column("nickname", .text)
                t.column("birthDate", .datetime)
                t.column("birthYear", .integer)
                t.column("deathDate", .datetime)
                t.column("deathYear", .integer)
                t.column("isLiving", .boolean).notNull().defaults(to: true)
                t.column("birthPlace", .text)
                t.column("gender", .text)
                t.column("notes", .text)
                t.column("profilePhotoFilename", .text)
                t.column("gedcomId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "relationship") { t in
                t.primaryKey("id", .text)
                t.column("fromPersonId", .text).notNull()
                    .references("person", onDelete: .cascade)
                t.column("toPersonId", .text).notNull()
                    .references("person", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("subtype", .text)
                t.column("startDate", .datetime)
                t.column("endDate", .datetime)
                t.column("createdAt", .datetime).notNull()

                t.uniqueKey(["fromPersonId", "toPersonId", "type"])
            }

            try db.create(table: "attachment") { t in
                t.primaryKey("id", .text)
                t.column("personId", .text).notNull()
                    .references("person", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("label", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "flashcardDeck") { t in
                t.primaryKey("id", .text)
                t.column("perspectivePersonId", .text).notNull()
                    .references("person", onDelete: .cascade)
                t.column("generatedAt", .datetime).notNull()
                t.column("cardCount", .integer).notNull()
            }

            try db.create(table: "flashcard") { t in
                t.primaryKey("id", .text)
                t.column("deckId", .text).notNull()
                    .references("flashcardDeck", onDelete: .cascade)
                t.column("question", .text).notNull()
                t.column("answer", .text).notNull()
                t.column("explanation", .text)
                t.column("chain", .text)
                t.column("status", .text).notNull().defaults(to: "unknown")
                t.column("lastReviewedAt", .datetime)
            }

            // Seed default settings
            try db.execute(
                sql: """
                    INSERT INTO appSettings (id, hasCompletedOnboarding, createdAt, updatedAt)
                    VALUES (1, 0, ?, ?)
                    """,
                arguments: [Date(), Date()]
            )
        }

        try migrator.migrate(dbQueue)
    }
}
