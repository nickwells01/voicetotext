import XCTest
@testable import VoiceToText

final class CustomVocabularyTests: XCTestCase {

    // MARK: - Empty Words

    func testEmptyWordsEmptySuffix() {
        let vocab = CustomVocabulary(words: [])
        XCTAssertEqual(vocab.promptSuffix, "")
    }

    // MARK: - Single Word

    func testSingleWordFormat() {
        let vocab = CustomVocabulary(words: ["Kubernetes"])
        XCTAssertTrue(vocab.promptSuffix.hasPrefix("\n\nIMPORTANT:"))
        XCTAssertTrue(vocab.promptSuffix.contains("Kubernetes"))
    }

    // MARK: - Multiple Words

    func testMultipleWordsCommaSeparated() {
        let vocab = CustomVocabulary(words: ["Swift", "Xcode", "Metal"])
        let suffix = vocab.promptSuffix
        XCTAssertTrue(suffix.contains("Swift"))
        XCTAssertTrue(suffix.contains("Xcode"))
        XCTAssertTrue(suffix.contains("Metal"))
        XCTAssertTrue(suffix.contains("Swift, Xcode, Metal"))
    }

    // MARK: - Special Characters

    func testSpecialCharactersPreserved() {
        let vocab = CustomVocabulary(words: ["C++", "ASP.NET", "node.js"])
        let suffix = vocab.promptSuffix
        XCTAssertTrue(suffix.contains("C++"))
        XCTAssertTrue(suffix.contains("ASP.NET"))
        XCTAssertTrue(suffix.contains("node.js"))
    }

    // MARK: - Codable Round Trip

    func testCodableRoundTrip() {
        let original = CustomVocabulary(words: ["Kubernetes", "gRPC", "C++"])
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try! encoder.encode(original)
        let decoded = try! decoder.decode(CustomVocabulary.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
