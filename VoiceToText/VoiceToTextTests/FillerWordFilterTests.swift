import XCTest
@testable import VoiceToText

final class FillerWordFilterTests: XCTestCase {

    func testRemovesCommonFillers() {
        let filter = FillerWordFilter()
        let input = "Um I think uh that this is basically a good idea"
        let result = filter.filter(input)
        XCTAssertFalse(result.contains("Um"))
        XCTAssertFalse(result.contains("uh"))
        XCTAssertFalse(result.contains("basically"))
        XCTAssertTrue(result.contains("think"))
        XCTAssertTrue(result.contains("good idea"))
    }

    func testRemovesMultiWordFillers() {
        let filter = FillerWordFilter()
        let input = "I mean you know it was kind of interesting"
        let result = filter.filter(input)
        XCTAssertFalse(result.lowercased().contains("i mean"))
        XCTAssertFalse(result.lowercased().contains("you know"))
        XCTAssertFalse(result.lowercased().contains("kind of"))
        XCTAssertTrue(result.contains("interesting"))
    }

    func testPreservesNonFillerWords() {
        let filter = FillerWordFilter()
        let input = "The actual meaning of the word is important"
        let result = filter.filter(input)
        // "actual" is a filler when used as "actually" but not "actual"
        // "The" and "meaning" should be preserved
        XCTAssertTrue(result.contains("meaning"))
        XCTAssertTrue(result.contains("important"))
    }

    func testDoesNotCreateDoubleSpaces() {
        let filter = FillerWordFilter()
        let input = "So um I went uh to the store"
        let result = filter.filter(input)
        XCTAssertFalse(result.contains("  "), "Should not contain double spaces after filler removal")
    }

    func testCaseInsensitive() {
        let filter = FillerWordFilter()
        let input = "UM this is UH a test BASICALLY"
        let result = filter.filter(input)
        XCTAssertFalse(result.contains("UM"))
        XCTAssertFalse(result.contains("UH"))
        XCTAssertFalse(result.contains("BASICALLY"))
    }

    func testEmptyInput() {
        let filter = FillerWordFilter()
        XCTAssertEqual(filter.filter(""), "")
    }

    func testNoFillersPreservesText() {
        let filter = FillerWordFilter()
        let input = "The quick brown fox jumps over the lazy dog"
        XCTAssertEqual(filter.filter(input), input)
    }

    func testCustomFillerWords() {
        let filter = FillerWordFilter(fillerWords: ["blah", "stuff"])
        let input = "I did blah and stuff yesterday"
        let result = filter.filter(input)
        XCTAssertFalse(result.contains("blah"))
        XCTAssertFalse(result.contains("stuff"))
    }
}
