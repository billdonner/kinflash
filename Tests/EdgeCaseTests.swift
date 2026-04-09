import XCTest
import GRDB
@testable import KinFlash

// MARK: - TreeService Edge Cases

final class TreeServiceEdgeCaseTests: XCTestCase {

    private func makeDB() throws -> (DatabaseManager, TreeService) {
        let db = try DatabaseManager(inMemory: true)
        return (db, TreeService(dbQueue: db.dbQueue))
    }

    private func makePerson(firstName: String, lastName: String? = nil, gender: Gender? = nil, birthYear: Int? = nil) -> Person {
        Person(id: UUID(), firstName: firstName, middleName: nil, lastName: lastName,
               nickname: nil, birthDate: nil, birthYear: birthYear, deathDate: nil, deathYear: nil,
               isLiving: true, birthPlace: nil, gender: gender, notes: nil,
               profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
    }

    func testDeletePersonCascadesFlashcards() throws {
        let (db, service) = try makeDB()
        let person = makePerson(firstName: "Alice")
        try service.addPerson(person)

        // Create a flashcard deck for this person
        let deck = FlashcardDeck(id: UUID(), perspectivePersonId: person.id, generatedAt: Date(), cardCount: 1)
        let card = Flashcard(id: UUID(), deckId: deck.id, question: "Q", answer: "A",
                             explanation: nil, chain: nil, status: .unknown, lastReviewedAt: nil)
        try db.dbQueue.write { database in
            try deck.insert(database)
            try card.insert(database)
        }

        try service.deletePerson(id: person.id)

        let deckCount = try db.dbQueue.read { database in try FlashcardDeck.fetchCount(database) }
        let cardCount = try db.dbQueue.read { database in try Flashcard.fetchCount(database) }
        XCTAssertEqual(deckCount, 0, "Deck should cascade delete")
        XCTAssertEqual(cardCount, 0, "Cards should cascade delete")
    }

    func testAddMultipleSpousesAllowed() throws {
        let (_, service) = try makeDB()
        let john = makePerson(firstName: "John", gender: .male)
        let wife1 = makePerson(firstName: "Alice", gender: .female)
        let wife2 = makePerson(firstName: "Beth", gender: .female)
        try service.addPerson(john)
        try service.addPerson(wife1)
        try service.addPerson(wife2)

        try service.addRelationship(from: john.id, to: wife1.id, type: .spouse)
        try service.addRelationship(from: john.id, to: wife2.id, type: .spouse)

        let rels = try service.fetchOutgoing(for: john.id)
        let spouseRels = rels.filter { $0.type == .spouse }
        XCTAssertEqual(spouseRels.count, 2, "Should allow multiple spouses")
    }

    func testFetchAllPeopleSorted() throws {
        let (_, service) = try makeDB()
        try service.addPerson(makePerson(firstName: "Zara", lastName: "Adams"))
        try service.addPerson(makePerson(firstName: "Alice", lastName: "Zulu"))
        try service.addPerson(makePerson(firstName: "Bob", lastName: "Adams"))

        let people = try service.fetchAllPeople()
        // Sorted by lastName then firstName
        XCTAssertEqual(people[0].firstName, "Bob")   // Adams, Bob
        XCTAssertEqual(people[1].firstName, "Zara")   // Adams, Zara
        XCTAssertEqual(people[2].firstName, "Alice")   // Zulu, Alice
    }

    func testUpdatePersonPreservesId() throws {
        let (_, service) = try makeDB()
        var person = makePerson(firstName: "Alice")
        try service.addPerson(person)

        person.firstName = "Alicia"
        try service.updatePerson(person)

        let fetched = try service.fetchPerson(id: person.id)
        XCTAssertEqual(fetched?.firstName, "Alicia")
        XCTAssertEqual(fetched?.id, person.id)
    }

    func testDeepCycleDetection() throws {
        let (_, service) = try makeDB()
        // A → B → C → D, then try D → A
        let a = makePerson(firstName: "A")
        let b = makePerson(firstName: "B")
        let c = makePerson(firstName: "C")
        let d = makePerson(firstName: "D")
        try [a, b, c, d].forEach { try service.addPerson($0) }

        try service.addRelationship(from: a.id, to: b.id, type: .parent)
        try service.addRelationship(from: b.id, to: c.id, type: .parent)
        try service.addRelationship(from: c.id, to: d.id, type: .parent)

        XCTAssertThrowsError(
            try service.addRelationship(from: d.id, to: a.id, type: .parent)
        ) { error in
            XCTAssertEqual(error as? TreeServiceError, .circularParentChain)
        }
    }
}

// MARK: - RelationshipResolver Edge Cases

final class RelationshipResolverEdgeCaseTests: XCTestCase {

    func testUnconnectedPeopleReturnNil() throws {
        let db = try DatabaseManager(inMemory: true)
        let now = Date()
        let alice = Person(id: UUID(), firstName: "Alice", middleName: nil, lastName: nil,
                           nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                           isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                           profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now)
        let bob = Person(id: UUID(), firstName: "Bob", middleName: nil, lastName: nil,
                         nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                         isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                         profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now)
        try db.dbQueue.write { database in
            try alice.insert(database)
            try bob.insert(database)
        }

        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let label = try resolver.resolve(from: alice.id, to: bob.id)
        XCTAssertNil(label, "Unconnected people should return nil")
    }

    func testResolveAllExcludesSelf() throws {
        let db = try DatabaseManager(inMemory: true)
        let now = Date()
        let person = Person(id: UUID(), firstName: "Solo", middleName: nil, lastName: nil,
                            nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                            isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                            profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now)
        try db.dbQueue.write { database in try person.insert(database) }

        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let all = try resolver.resolveAll(from: person.id)
        XCTAssertFalse(all.keys.contains(person.id), "Should not include self in resolveAll")
    }

    func testStepParentPrefix() throws {
        let db = try DatabaseManager(inMemory: true)
        let now = Date()
        let child = Person(id: UUID(), firstName: "Kid", middleName: nil, lastName: nil,
                           nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                           isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                           profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now)
        let stepDad = Person(id: UUID(), firstName: "StepDad", middleName: nil, lastName: nil,
                             nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                             isLiving: true, birthPlace: nil, gender: .male, notes: nil,
                             profilePhotoFilename: nil, gedcomId: nil, createdAt: now, updatedAt: now)

        try db.dbQueue.write { database in
            try child.insert(database)
            try stepDad.insert(database)
            try Relationship(id: UUID(), fromPersonId: stepDad.id, toPersonId: child.id,
                             type: .parent, subtype: .step, startDate: nil, endDate: nil, createdAt: now)
                .insert(database)
        }

        let resolver = RelationshipResolver(dbQueue: db.dbQueue)
        let label = try resolver.resolve(from: child.id, to: stepDad.id)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.label.lowercased().contains("step"), "Should include step prefix: got '\(label!.label)'")
    }
}

// MARK: - GEDCOM Parser Edge Cases

final class GEDCOMParserEdgeCaseTests: XCTestCase {

    func testParseNoNameIndividual() {
        let gedcom = """
        0 HEAD
        1 SOUR Test
        1 GEDC
        2 VERS 5.5.1
        0 @I1@ INDI
        1 SEX M
        0 TRLR
        """
        let result = GEDCOMParser().parse(content: gedcom)
        XCTAssertEqual(result.people.count, 1)
        XCTAssertEqual(result.people[0].firstName, "Unknown")
    }

    func testParseDateFormats() {
        let gedcom = """
        0 HEAD
        1 SOUR Test
        1 GEDC
        2 VERS 5.5.1
        0 @I1@ INDI
        1 NAME Test /Person/
        1 BIRT
        2 DATE JUN 1945
        0 TRLR
        """
        let result = GEDCOMParser().parse(content: gedcom)
        // "JUN 1945" should parse as a date or at least extract the year
        let person = result.people.first
        XCTAssertNotNil(person)
        // Either birthDate or birthYear should be populated
        XCTAssertTrue(person?.birthDate != nil || person?.birthYear == 1945,
                      "Should extract year from partial date")
    }

    func testParseUnicodeNames() {
        let gedcom = """
        0 HEAD
        1 SOUR Test
        1 GEDC
        2 VERS 5.5.1
        0 @I1@ INDI
        1 NAME José /García/
        0 TRLR
        """
        let result = GEDCOMParser().parse(content: gedcom)
        XCTAssertEqual(result.people.first?.firstName, "José")
        XCTAssertEqual(result.people.first?.lastName, "García")
    }

    func testParseEmptyFamilyRecord() {
        let gedcom = """
        0 HEAD
        1 SOUR Test
        1 GEDC
        2 VERS 5.5.1
        0 @F1@ FAM
        0 TRLR
        """
        let result = GEDCOMParser().parse(content: gedcom)
        XCTAssertEqual(result.people.count, 0)
        XCTAssertEqual(result.relationships.count, 0)
    }
}

// MARK: - Person Model Tests

final class PersonModelTests: XCTestCase {

    func testDisplayNameWithAllParts() {
        let person = Person(id: UUID(), firstName: "John", middleName: "Robert", lastName: "Smith",
                            nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                            isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                            profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(person.displayName, "John Robert Smith")
    }

    func testDisplayNameFirstOnly() {
        let person = Person(id: UUID(), firstName: "Madonna", middleName: nil, lastName: nil,
                            nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                            isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                            profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(person.displayName, "Madonna")
    }

    func testDisplayYearsLiving() {
        let person = Person(id: UUID(), firstName: "Test", middleName: nil, lastName: nil,
                            nickname: nil, birthDate: nil, birthYear: 1990, deathDate: nil, deathYear: nil,
                            isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                            profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(person.displayYears, "b. 1990")
    }

    func testDisplayYearsDeceased() {
        let person = Person(id: UUID(), firstName: "Test", middleName: nil, lastName: nil,
                            nickname: nil, birthDate: nil, birthYear: 1920, deathDate: nil, deathYear: 2000,
                            isLiving: false, birthPlace: nil, gender: nil, notes: nil,
                            profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(person.displayYears, "1920 — 2000")
    }

    func testDisplayYearsDeceasedUnknownDeath() {
        let person = Person(id: UUID(), firstName: "Test", middleName: nil, lastName: nil,
                            nickname: nil, birthDate: nil, birthYear: 1920, deathDate: nil, deathYear: nil,
                            isLiving: false, birthPlace: nil, gender: nil, notes: nil,
                            profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(person.displayYears, "1920 — ?")
    }

    func testDisplayYearsNoBirthYear() {
        let person = Person(id: UUID(), firstName: "Test", middleName: nil, lastName: nil,
                            nickname: nil, birthDate: nil, birthYear: nil, deathDate: nil, deathYear: nil,
                            isLiving: true, birthPlace: nil, gender: nil, notes: nil,
                            profilePhotoFilename: nil, gedcomId: nil, createdAt: Date(), updatedAt: Date())
        XCTAssertNil(person.displayYears)
    }
}

// MARK: - InterviewService Fuzzy Matching

final class FuzzyMatchTests: XCTestCase {

    func testFuzzyMatchCaseInsensitive() throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let person1 = ExtractedPerson(firstName: "John", middleName: nil, lastName: "Smith",
                                       nickname: nil, birthYear: 1945, birthPlace: nil,
                                       isLiving: true, deathYear: nil, gender: "male",
                                       relationships: [], isComplete: true)
        _ = try service.saveExtractedPerson(person1)

        // Same person, different case
        let person2 = ExtractedPerson(firstName: "john", middleName: nil, lastName: "smith",
                                       nickname: nil, birthYear: 1945, birthPlace: nil,
                                       isLiving: true, deathYear: nil, gender: "male",
                                       relationships: [], isComplete: true)
        _ = try service.saveExtractedPerson(person2)

        let count = try db.dbQueue.read { database in try Person.fetchCount(database) }
        XCTAssertEqual(count, 1, "Case-insensitive match should not create duplicate")
    }

    func testFuzzyMatchBirthYearTolerance() throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let person1 = ExtractedPerson(firstName: "John", middleName: nil, lastName: "Smith",
                                       nickname: nil, birthYear: 1945, birthPlace: nil,
                                       isLiving: true, deathYear: nil, gender: nil,
                                       relationships: [], isComplete: true)
        _ = try service.saveExtractedPerson(person1)

        // Birth year off by 1 — should still match
        let person2 = ExtractedPerson(firstName: "John", middleName: nil, lastName: "Smith",
                                       nickname: nil, birthYear: 1946, birthPlace: nil,
                                       isLiving: true, deathYear: nil, gender: nil,
                                       relationships: [], isComplete: true)
        _ = try service.saveExtractedPerson(person2)

        let count = try db.dbQueue.read { database in try Person.fetchCount(database) }
        XCTAssertEqual(count, 1, "Birth year within 2 should match as same person")
    }

    func testFuzzyMatchDifferentBirthYearCreatesSeparate() throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let person1 = ExtractedPerson(firstName: "John", middleName: nil, lastName: "Smith",
                                       nickname: nil, birthYear: 1945, birthPlace: nil,
                                       isLiving: true, deathYear: nil, gender: nil,
                                       relationships: [], isComplete: true)
        _ = try service.saveExtractedPerson(person1)

        // Birth year off by 10 — should be different person (John Smith Sr vs Jr)
        let person2 = ExtractedPerson(firstName: "John", middleName: nil, lastName: "Smith",
                                       nickname: nil, birthYear: 1975, birthPlace: nil,
                                       isLiving: true, deathYear: nil, gender: nil,
                                       relationships: [], isComplete: true)
        _ = try service.saveExtractedPerson(person2)

        let count = try db.dbQueue.read { database in try Person.fetchCount(database) }
        XCTAssertEqual(count, 2, "Different birth years should create separate people")
    }

    func testFuzzyMatchFirstNameOnlyWithNilLastName() throws {
        let db = try DatabaseManager(inMemory: true)
        let provider = LocalInterviewProvider()
        let service = InterviewService(dbQueue: db.dbQueue, aiProvider: provider)

        let person1 = ExtractedPerson(firstName: "Teddy", middleName: nil, lastName: nil,
                                       nickname: nil, birthYear: nil, birthPlace: nil,
                                       isLiving: true, deathYear: nil, gender: nil,
                                       relationships: [], isComplete: true)
        _ = try service.saveExtractedPerson(person1)

        let person2 = ExtractedPerson(firstName: "Teddy", middleName: nil, lastName: nil,
                                       nickname: nil, birthYear: nil, birthPlace: nil,
                                       isLiving: true, deathYear: nil, gender: nil,
                                       relationships: [], isComplete: true)
        _ = try service.saveExtractedPerson(person2)

        let count = try db.dbQueue.read { database in try Person.fetchCount(database) }
        XCTAssertEqual(count, 1, "Same first-name-only person should match")
    }
}

// MARK: - AppSettings Tests

final class AppSettingsTests: XCTestCase {

    func testDefaultSettings() throws {
        let db = try DatabaseManager(inMemory: true)
        let settings = try db.dbQueue.read { database in try AppSettings.current(database) }
        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertNil(settings.rootPersonId)
        XCTAssertNil(settings.selectedAIProvider)
    }

    func testUpdateSettings() throws {
        let db = try DatabaseManager(inMemory: true)
        try db.dbQueue.write { database in
            var settings = try AppSettings.current(database)
            settings.hasCompletedOnboarding = true
            settings.selectedAIProvider = "anthropic"
            settings.updatedAt = Date()
            try settings.update(database)
        }

        let settings = try db.dbQueue.read { database in try AppSettings.current(database) }
        XCTAssertTrue(settings.hasCompletedOnboarding)
        XCTAssertEqual(settings.selectedAIProvider, "anthropic")
    }
}

// MARK: - LocalInterviewProvider Parsing Edge Cases

final class LocalProviderParsingTests: XCTestCase {

    func testSingleWordNameAccepted() async throws {
        let provider = LocalInterviewProvider()
        let response = try await provider.chat(messages: [
            AIMessage(role: .user, content: "Cher")
        ])
        let people = extractAll(from: response)
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people.first?.firstName, "Cher")
    }

    func testHyphenatedNameAccepted() async throws {
        let provider = LocalInterviewProvider()
        let response = try await provider.chat(messages: [
            AIMessage(role: .user, content: "Mary-Jane Watson-Parker")
        ])
        let people = extractAll(from: response)
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people.first?.firstName, "Mary-Jane")
    }

    func testEmptyInputProducesNoPeople() async throws {
        let provider = LocalInterviewProvider()
        let response = try await provider.chat(messages: [
            AIMessage(role: .user, content: "John"),
            AIMessage(role: .assistant, content: "Parents?"),
            AIMessage(role: .user, content: "   ")
        ])
        let people = extractAll(from: response)
        XCTAssertEqual(people.count, 0)
    }

    func testQuestionMarkInputRejected() async throws {
        let provider = LocalInterviewProvider()
        let response = try await provider.chat(messages: [
            AIMessage(role: .user, content: "John"),
            AIMessage(role: .assistant, content: "Parents?"),
            AIMessage(role: .user, content: "What do you mean?")
        ])
        let people = extractAll(from: response)
        XCTAssertEqual(people.count, 0, "Questions should not be parsed as names")
    }

    private func extractAll(from text: String) -> [ExtractedPerson] {
        let pattern = #"```json[^\n]*\n([\s\S]*?)\n\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            guard let data = String(text[range]).data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ExtractedPerson.self, from: data)
        }
    }
}
