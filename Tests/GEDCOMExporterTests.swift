import XCTest
import GRDB
@testable import KinFlash

final class GEDCOMExporterTests: XCTestCase {

    func testRoundTrip() throws {
        let originalGEDCOM = """
        0 HEAD
        1 SOUR KinFlash
        1 GEDC
        2 VERS 5.5.1
        0 @I1@ INDI
        1 NAME Robert /Smith/
        1 SEX M
        1 BIRT
        2 DATE 15 FEB 1920
        2 PLAC Detroit, Michigan
        1 DEAT
        2 DATE 8 NOV 1990
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME Helen /Brown/
        1 SEX F
        1 BIRT
        2 DATE 22 AUG 1922
        1 FAMS @F1@
        0 @F1@ FAM
        1 HUSB @I1@
        1 WIFE @I2@
        0 TRLR
        """

        // Import
        let parser = GEDCOMParser()
        let result = parser.parse(content: originalGEDCOM)
        XCTAssertEqual(result.people.count, 2)

        let db = try DatabaseManager(inMemory: true)
        try parser.importToDatabase(result, dbQueue: db.dbQueue)

        // Export
        let exporter = GEDCOMExporter(dbQueue: db.dbQueue)
        let exported = try exporter.export()

        // Verify exported content has the key elements
        XCTAssertTrue(exported.contains("INDI"))
        XCTAssertTrue(exported.contains("Robert"))
        XCTAssertTrue(exported.contains("Smith"))
        XCTAssertTrue(exported.contains("Helen"))
        XCTAssertTrue(exported.contains("Brown"))
        XCTAssertTrue(exported.contains("FAM"))
        XCTAssertTrue(exported.contains("HUSB"))
        XCTAssertTrue(exported.contains("WIFE"))
        XCTAssertTrue(exported.contains("TRLR"))

        // Re-import the exported content
        let reResult = parser.parse(content: exported)
        XCTAssertEqual(reResult.people.count, 2)

        let robert = reResult.people.first { $0.firstName == "Robert" }
        XCTAssertNotNil(robert)
        XCTAssertEqual(robert?.lastName, "Smith")
        XCTAssertEqual(robert?.gender, .male)
    }

    func testExportEmptyDatabase() throws {
        let db = try DatabaseManager(inMemory: true)
        let exporter = GEDCOMExporter(dbQueue: db.dbQueue)
        let exported = try exporter.export()

        XCTAssertTrue(exported.contains("HEAD"))
        XCTAssertTrue(exported.contains("TRLR"))
        XCTAssertFalse(exported.contains("INDI"))
    }
}
