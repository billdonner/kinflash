import Foundation
import GRDB

enum Gender: String, Codable, Sendable, DatabaseValueConvertible {
    case male
    case female
    case nonBinary
    case unknown
}

struct Person: Codable, Sendable, Identifiable {
    var id: UUID
    var firstName: String
    var middleName: String?
    var lastName: String?
    var nickname: String?
    var birthDate: Date?
    var birthYear: Int?
    var deathDate: Date?
    var deathYear: Int?
    var isLiving: Bool
    var birthPlace: String?
    var gender: Gender?
    var notes: String?
    var profilePhotoFilename: String?
    var gedcomId: String?
    var createdAt: Date
    var updatedAt: Date

    var displayName: String {
        let parts = [firstName, middleName, lastName].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    var displayYears: String? {
        let birth = birthDate.map { Calendar.current.component(.year, from: $0) } ?? birthYear
        let death = deathDate.map { Calendar.current.component(.year, from: $0) } ?? deathYear
        guard let b = birth else { return nil }
        if let d = death {
            return "\(b) — \(d)"
        } else if !isLiving {
            return "\(b) — ?"
        } else {
            return "b. \(b)"
        }
    }
}

extension Person: FetchableRecord, PersistableRecord {
    static let databaseTableName = "person"
}
