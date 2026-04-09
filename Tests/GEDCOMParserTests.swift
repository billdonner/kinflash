import XCTest
import GRDB
@testable import KinFlash

final class GEDCOMParserTests: XCTestCase {

    let sampleGEDCOM = """
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
    2 PLAC Detroit, Michigan
    1 DEAT
    2 DATE 1 MAR 2005
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME John /Smith/
    1 SEX M
    1 BIRT
    2 DATE 12 JUN 1945
    2 PLAC Chicago, Illinois
    1 DEAT
    2 DATE 3 MAR 2018
    1 FAMC @F1@
    1 FAMS @F2@
    0 @I4@ INDI
    1 NAME Carol /Smith/
    1 SEX F
    1 BIRT
    2 DATE 7 OCT 1948
    2 PLAC Chicago, Illinois
    1 FAMC @F1@
    0 @I5@ INDI
    1 NAME Mary /Jones/
    1 SEX F
    1 BIRT
    2 DATE 3 MAR 1948
    1 FAMS @F2@
    0 @I6@ INDI
    1 NAME Michael /Smith/
    1 SEX M
    1 BIRT
    2 DATE 15 SEP 1970
    1 FAMC @F2@
    0 @I7@ INDI
    1 NAME David /Smith/
    1 SEX M
    1 BIRT
    2 DATE 4 JAN 1973
    1 FAMC @F2@
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    1 CHIL @I3@
    1 CHIL @I4@
    0 @F2@ FAM
    1 HUSB @I3@
    1 WIFE @I5@
    1 CHIL @I6@
    1 CHIL @I7@
    0 TRLR
    """

    func testParsesPeopleCount() {
        let parser = GEDCOMParser()
        let result = parser.parse(content: sampleGEDCOM)

        XCTAssertEqual(result.people.count, 7)
        XCTAssertEqual(result.errors.count, 0)
    }

    func testParsesPersonDetails() {
        let parser = GEDCOMParser()
        let result = parser.parse(content: sampleGEDCOM)

        let robert = result.people.first { $0.firstName == "Robert" && $0.lastName == "Smith" }
        XCTAssertNotNil(robert)
        XCTAssertEqual(robert?.gender, .male)
        XCTAssertEqual(robert?.birthPlace, "Detroit, Michigan")
        XCTAssertFalse(robert!.isLiving)
        XCTAssertNotNil(robert?.birthDate)
        XCTAssertNotNil(robert?.deathDate)
    }

    func testParsesLivingPerson() {
        let parser = GEDCOMParser()
        let result = parser.parse(content: sampleGEDCOM)

        let carol = result.people.first { $0.firstName == "Carol" }
        XCTAssertNotNil(carol)
        XCTAssertTrue(carol!.isLiving) // No DEAT record
        XCTAssertEqual(carol?.gender, .female)
    }

    func testParsesRelationships() {
        let parser = GEDCOMParser()
        let result = parser.parse(content: sampleGEDCOM)

        // Spouse relationships (2 per pair, so 2 pairs = 4)
        let spouseRels = result.relationships.filter { $0.type == .spouse }
        XCTAssertEqual(spouseRels.count, 4) // Robert-Helen + John-Mary, 2 rows each

        // Parent relationships: Robert→John, Robert→Carol, Helen→John, Helen→Carol, John→Michael, John→David, Mary→Michael, Mary→David
        let parentRels = result.relationships.filter { $0.type == .parent }
        XCTAssertEqual(parentRels.count, 8)

        // Sibling relationships: John-Carol (2 rows) + Michael-David (2 rows) = 4
        let siblingRels = result.relationships.filter { $0.type == .sibling }
        XCTAssertEqual(siblingRels.count, 4)
    }

    func testImportToDatabase() throws {
        let parser = GEDCOMParser()
        let result = parser.parse(content: sampleGEDCOM)

        let db = try DatabaseManager(inMemory: true)
        try parser.importToDatabase(result, dbQueue: db.dbQueue)

        let personCount = try db.dbQueue.read { database in
            try Person.fetchCount(database)
        }
        XCTAssertEqual(personCount, 7)

        let relCount = try db.dbQueue.read { database in
            try Relationship.fetchCount(database)
        }
        XCTAssertEqual(relCount, 16) // 4 spouse + 8 parent + 4 sibling
    }

    func testParsesNameCorrectly() {
        let parser = GEDCOMParser()
        let simpleGEDCOM = """
        0 HEAD
        1 SOUR Test
        1 GEDC
        2 VERS 5.5.1
        0 @I1@ INDI
        1 NAME John Robert /Smith/
        1 SEX M
        0 TRLR
        """
        let result = parser.parse(content: simpleGEDCOM)
        XCTAssertEqual(result.people.count, 1)
        XCTAssertEqual(result.people.first?.firstName, "John Robert")
        XCTAssertEqual(result.people.first?.lastName, "Smith")
    }

    func testEmptyGEDCOM() {
        let parser = GEDCOMParser()
        let result = parser.parse(content: "0 HEAD\n0 TRLR\n")
        XCTAssertEqual(result.people.count, 0)
        XCTAssertEqual(result.relationships.count, 0)
    }

    func testMalformedLinesSkipped() {
        let parser = GEDCOMParser()
        let badGEDCOM = """
        0 HEAD
        INVALID LINE HERE
        0 @I1@ INDI
        1 NAME Test /Person/
        0 TRLR
        """
        let result = parser.parse(content: badGEDCOM)
        XCTAssertEqual(result.people.count, 1)
        XCTAssertEqual(result.errors.count, 1)
    }
}
