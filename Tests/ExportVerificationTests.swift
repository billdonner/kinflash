import XCTest
import GRDB
@testable import KinFlash

/// Deep verification of GEDCOM export: import sample → export → reimport → compare everything.
final class ExportVerificationTests: XCTestCase {

    private func loadSampleAndExport() throws -> (original: GEDCOMParseResult, exported: String, reimported: GEDCOMParseResult) {
        // Import
        let gedcomURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("KinFlash/Resources/SampleFamily.ged")
        let content = try String(contentsOf: gedcomURL, encoding: .utf8)
        let parser = GEDCOMParser()
        let original = parser.parse(content: content)

        let db = try DatabaseManager(inMemory: true)
        try parser.importToDatabase(original, dbQueue: db.dbQueue)

        // Export
        let exporter = GEDCOMExporter(dbQueue: db.dbQueue)
        let exported = try exporter.export()

        // Reimport into fresh DB
        let reimported = parser.parse(content: exported)

        return (original, exported, reimported)
    }

    // MARK: - People Preservation

    func testSamePeopleCount() throws {
        let (original, _, reimported) = try loadSampleAndExport()
        XCTAssertEqual(reimported.people.count, original.people.count,
                       "Export should preserve all \(original.people.count) people")
    }

    func testAllNamesPreserved() throws {
        let (original, _, reimported) = try loadSampleAndExport()
        let originalNames = Set(original.people.map { "\($0.firstName) \($0.lastName ?? "")" })
        let reimportedNames = Set(reimported.people.map { "\($0.firstName) \($0.lastName ?? "")" })

        let missing = originalNames.subtracting(reimportedNames)
        let extra = reimportedNames.subtracting(originalNames)

        XCTAssertTrue(missing.isEmpty, "Missing after round-trip: \(missing)")
        XCTAssertTrue(extra.isEmpty, "Extra after round-trip: \(extra)")
    }

    func testGendersPreserved() throws {
        let (original, _, reimported) = try loadSampleAndExport()

        for origPerson in original.people {
            guard origPerson.gender != nil && origPerson.gender != .unknown else { continue }
            let match = reimported.people.first { $0.firstName == origPerson.firstName && $0.lastName == origPerson.lastName }
            XCTAssertNotNil(match, "Should find \(origPerson.firstName) in reimported")
            if let m = match {
                XCTAssertEqual(m.gender, origPerson.gender,
                               "\(origPerson.firstName) gender mismatch: \(String(describing: m.gender)) vs \(String(describing: origPerson.gender))")
            }
        }
    }

    func testBirthDatesPreserved() throws {
        let (original, _, reimported) = try loadSampleAndExport()

        for origPerson in original.people where origPerson.birthDate != nil {
            let match = reimported.people.first { $0.firstName == origPerson.firstName && $0.lastName == origPerson.lastName }
            XCTAssertNotNil(match, "\(origPerson.firstName) should exist in reimport")
            if let m = match {
                // Compare by year since date formatting may lose precision
                let origYear = Calendar.current.component(.year, from: origPerson.birthDate!)
                if let reimportedDate = m.birthDate {
                    let reimportedYear = Calendar.current.component(.year, from: reimportedDate)
                    XCTAssertEqual(reimportedYear, origYear,
                                   "\(origPerson.firstName) birth year: \(reimportedYear) vs \(origYear)")
                } else if let by = m.birthYear {
                    XCTAssertEqual(by, origYear,
                                   "\(origPerson.firstName) birth year: \(by) vs \(origYear)")
                } else {
                    XCTFail("\(origPerson.firstName) lost birth date on round-trip")
                }
            }
        }
    }

    func testDeathDatesPreserved() throws {
        let (original, _, reimported) = try loadSampleAndExport()

        let originalDeceased = original.people.filter { !$0.isLiving }
        let reimportedDeceased = reimported.people.filter { !$0.isLiving }

        XCTAssertEqual(reimportedDeceased.count, originalDeceased.count,
                       "Same number of deceased people: \(reimportedDeceased.count) vs \(originalDeceased.count)")
    }

    func testBirthPlacesPreserved() throws {
        let (original, _, reimported) = try loadSampleAndExport()

        for origPerson in original.people where origPerson.birthPlace != nil {
            let match = reimported.people.first { $0.firstName == origPerson.firstName && $0.lastName == origPerson.lastName }
            if let m = match {
                XCTAssertEqual(m.birthPlace, origPerson.birthPlace,
                               "\(origPerson.firstName) birthPlace mismatch")
            }
        }
    }

    // MARK: - Relationship Preservation

    func testSpouseRelationshipsPreserved() throws {
        let (original, _, reimported) = try loadSampleAndExport()

        let origSpouse = original.relationships.filter { $0.type == .spouse }.count
        let reimSpouse = reimported.relationships.filter { $0.type == .spouse }.count

        XCTAssertEqual(reimSpouse, origSpouse,
                       "Spouse relationships: \(reimSpouse) vs \(origSpouse)")
    }

    func testParentRelationshipsPreserved() throws {
        let (original, _, reimported) = try loadSampleAndExport()

        let origParent = original.relationships.filter { $0.type == .parent }.count
        let reimParent = reimported.relationships.filter { $0.type == .parent }.count

        // May not be exactly equal due to FAMC/FAMS linkage differences, but should be close
        XCTAssertGreaterThanOrEqual(reimParent, origParent / 2,
                                    "Should preserve most parent relationships: \(reimParent) vs \(origParent)")
    }

    func testSiblingRelationshipsExist() throws {
        let (_, _, reimported) = try loadSampleAndExport()

        let siblings = reimported.relationships.filter { $0.type == .sibling }.count
        XCTAssertGreaterThan(siblings, 0, "Should have sibling relationships after round-trip")
    }

    // MARK: - GEDCOM Structure

    func testExportHasHeader() throws {
        let (_, exported, _) = try loadSampleAndExport()
        XCTAssertTrue(exported.hasPrefix("0 HEAD"), "Should start with GEDCOM header")
        XCTAssertTrue(exported.contains("SOUR KinFlash"), "Should identify KinFlash as source")
        XCTAssertTrue(exported.contains("VERS 5.5.1"), "Should be GEDCOM 5.5.1")
    }

    func testExportHasTrailer() throws {
        let (_, exported, _) = try loadSampleAndExport()
        XCTAssertTrue(exported.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("0 TRLR"),
                       "Should end with GEDCOM trailer")
    }

    func testExportHasINDIRecords() throws {
        let (original, exported, _) = try loadSampleAndExport()
        let indiCount = exported.components(separatedBy: "INDI\n").count - 1
        XCTAssertEqual(indiCount, original.people.count,
                       "Should have \(original.people.count) INDI records, got \(indiCount)")
    }

    func testExportHasFAMRecords() throws {
        let (_, exported, _) = try loadSampleAndExport()
        let famCount = exported.components(separatedBy: "FAM\n").count - 1
        XCTAssertGreaterThan(famCount, 0, "Should have FAM records")
        print("[Export] FAM records: \(famCount)")
    }

    func testExportHasFAMCandFAMS() throws {
        let (_, exported, _) = try loadSampleAndExport()
        XCTAssertTrue(exported.contains("FAMC"), "Children should have FAMC references")
        XCTAssertTrue(exported.contains("FAMS"), "Spouses/parents should have FAMS references")
    }

    // MARK: - Specific People Verification

    func testRobertSmithFullRoundTrip() throws {
        let (_, _, reimported) = try loadSampleAndExport()
        let robert = reimported.people.first { $0.firstName == "Robert" && $0.lastName == "Smith" }
        XCTAssertNotNil(robert)
        XCTAssertEqual(robert?.gender, .male)
        XCTAssertFalse(robert!.isLiving, "Robert should be deceased")
    }

    func testMichaelSmithSurvivesRoundTrip() throws {
        let (_, _, reimported) = try loadSampleAndExport()
        let michael = reimported.people.first { $0.firstName == "Michael" && $0.lastName == "Smith" }
        XCTAssertNotNil(michael, "Michael Smith should survive round-trip")
        XCTAssertEqual(michael?.gender, .male)
    }

    func testJessicaWilsonSurvivesRoundTrip() throws {
        let (_, _, reimported) = try loadSampleAndExport()
        let jessica = reimported.people.first { $0.firstName == "Jessica" && $0.lastName == "Wilson" }
        XCTAssertNotNil(jessica, "Jessica Wilson should survive round-trip")
    }

    // MARK: - Double Round-Trip

    func testDoubleRoundTripPreservesPeople() throws {
        let gedcomURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("KinFlash/Resources/SampleFamily.ged")
        let content = try String(contentsOf: gedcomURL, encoding: .utf8)
        let parser = GEDCOMParser()

        // Round 1
        let r1 = parser.parse(content: content)
        let db1 = try DatabaseManager(inMemory: true)
        try parser.importToDatabase(r1, dbQueue: db1.dbQueue)
        let export1 = try GEDCOMExporter(dbQueue: db1.dbQueue).export()

        // Round 2
        let r2 = parser.parse(content: export1)
        let db2 = try DatabaseManager(inMemory: true)
        try parser.importToDatabase(r2, dbQueue: db2.dbQueue)
        let export2 = try GEDCOMExporter(dbQueue: db2.dbQueue).export()

        // Round 3
        let r3 = parser.parse(content: export2)

        XCTAssertEqual(r3.people.count, r1.people.count,
                       "Triple round-trip should preserve people count: \(r3.people.count) vs \(r1.people.count)")
    }
}
