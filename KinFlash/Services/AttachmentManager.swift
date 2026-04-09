import Foundation
import GRDB

struct AttachmentManager: Sendable {
    let dbQueue: DatabaseQueue

    private var baseDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("kinflash/people")
    }

    /// Adds an attachment atomically: inserts the DB row first, then copies the file.
    /// If the file copy fails, the DB row is rolled back. If the DB insert fails,
    /// no file is copied. No orphaned files or dangling rows.
    func addAttachment(personId: UUID, type: AttachmentType, sourceURL: URL, label: String?) throws -> Attachment {
        let filename = UUID().uuidString + "_" + sourceURL.lastPathComponent
        let destDir = directory(for: personId, type: type)
        let destURL = destDir.appendingPathComponent(filename)

        let now = Date()
        let attachment = Attachment(
            id: UUID(),
            personId: personId,
            type: type,
            filename: filename,
            label: label,
            createdAt: now,
            updatedAt: now
        )

        // Insert DB row and copy file inside a transaction.
        // If either fails, both are rolled back.
        try dbQueue.write { db in
            try attachment.insert(db)

            // Copy file after successful insert — if this throws,
            // GRDB rolls back the transaction automatically.
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        }

        return attachment
    }

    func deleteAttachment(id: UUID) throws {
        try dbQueue.write { db in
            guard let attachment = try Attachment.fetchOne(db, key: id) else { return }
            let fileURL = directory(for: attachment.personId, type: attachment.type)
                .appendingPathComponent(attachment.filename)
            try? FileManager.default.removeItem(at: fileURL)
            _ = try Attachment.deleteOne(db, key: id)
        }
    }

    func fetchAttachments(personId: UUID, type: AttachmentType? = nil) throws -> [Attachment] {
        try dbQueue.read { db in
            var query = Attachment.filter(Column("personId") == personId)
            if let type = type {
                query = query.filter(Column("type") == type.rawValue)
            }
            return try query.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    func fileURL(for attachment: Attachment) -> URL {
        directory(for: attachment.personId, type: attachment.type)
            .appendingPathComponent(attachment.filename)
    }

    private func directory(for personId: UUID, type: AttachmentType) -> URL {
        let subdir = type == .photo ? "photos" : "documents"
        return baseDirectory
            .appendingPathComponent(personId.uuidString)
            .appendingPathComponent(subdir)
    }
}
