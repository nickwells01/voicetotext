import XCTest
@testable import VoiceToText

final class AppContextDetectorTests: XCTestCase {

    // MARK: - Known Bundle ID Mappings

    func testKnownBundleIDsReturnCorrectCategory() {
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.apple.mail"), .email)
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.tinyspeck.slackmacgap"), .messaging)
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.apple.iWork.Pages"), .document)
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.atebits.Tweetie2"), .social)
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.apple.Notes"), .notes)
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.apple.Safari"), .browser)
    }

    // MARK: - Nil and Unknown Bundle IDs

    func testNilBundleIDReturnsGeneral() {
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: nil), .general)
    }

    func testUnknownBundleIDReturnsGeneral() {
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.example.unknown"), .general)
    }

    // MARK: - Heuristic Fallbacks

    func testHeuristicMailFallback() {
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.example.mailapp"), .email)
    }

    func testHeuristicCodeFallback() {
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.example.mycode"), .code)
    }

    func testHeuristicNotesFallback() {
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.example.mynotes"), .notes)
    }

    func testHeuristicIsCaseInsensitive() {
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "COM.EXAMPLE.MAILAPP"), .email)
    }

    // MARK: - Exact Mapping Priority

    func testExactMappingTakesPriorityOverHeuristic() {
        // "com.apple.Notes" contains "notes" which would match the heuristic,
        // but the exact mapping should resolve it to .notes regardless.
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.apple.Notes"), .notes)
    }

    // MARK: - Prompt Modifier

    func testPromptModifierNonEmptyForNonGeneral() {
        for category in AppCategory.allCases where category != .general {
            let modifier = AppContextDetector.promptModifier(for: category)
            XCTAssertFalse(modifier.isEmpty, "\(category.rawValue) should have a non-empty prompt modifier")
        }
    }

    func testPromptModifierEmptyForGeneral() {
        XCTAssertEqual(AppContextDetector.promptModifier(for: .general), "")
    }
}
