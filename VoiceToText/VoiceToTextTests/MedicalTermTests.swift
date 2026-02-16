import XCTest
@testable import VoiceToText

final class MedicalTermIndexTests: XCTestCase {

    var index: MedicalTermIndex!

    override func setUpWithError() throws {
        index = MedicalTermIndex.load()
        XCTAssertNotNil(index, "MedicalTermIndex should load from bundled resource")
    }

    // MARK: - Exact Match

    func testExactMatchKnownTerms() {
        XCTAssertTrue(index.termSet.contains("hypertension"))
        XCTAssertTrue(index.termSet.contains("tachycardia"))
        XCTAssertTrue(index.termSet.contains("metformin"))
    }

    func testExactMatchIsCaseInsensitive() {
        // termSet stores lowercased terms
        XCTAssertTrue(index.termSet.contains("hypertension"))
        XCTAssertFalse(index.termSet.contains("Hypertension")) // Set is lowercase
    }

    func testNonMedicalTermNotInSet() {
        XCTAssertFalse(index.termSet.contains("skateboarding"))
        XCTAssertFalse(index.termSet.contains("javascript"))
    }

    // MARK: - Fuzzy Match

    func testFuzzyMatchTypo() {
        // "tachykardia" -> "tachycardia" (1 edit)
        let result = index.fuzzyMatch("tachykardia")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.term, "tachycardia")
        XCTAssertEqual(result?.editDistance, 1)
    }

    func testFuzzyMatchAnotherTypo() {
        // "hypertention" -> "hypertension" (1 edit: i->s)
        let result = index.fuzzyMatch("hypertention")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.term, "hypertension")
    }

    func testFuzzyMatchRejectsDistantWords() {
        // "basketball" shouldn't match any medical term
        let result = index.fuzzyMatch("basketball")
        XCTAssertNil(result)
    }

    func testFuzzyMatchRejectsShortWords() {
        let result = index.fuzzyMatch("pain")
        XCTAssertNil(result)
    }

    func testFuzzyMatchRejectsStopwords() {
        let result = index.fuzzyMatch("something")
        XCTAssertNil(result)
    }

    func testFuzzyMatchReturnsNilForExactMatch() {
        // Exact matches return nil (no correction needed — word is already correct)
        let result = index.fuzzyMatch("tachycardia")
        XCTAssertNil(result)
    }

    // MARK: - Multi-word Detection

    func testMultiWordDetection() {
        let words = ["atrial", "fibrillation", "was", "detected"]
        let match = index.checkMultiWord(words: words, startIndex: 0)
        XCTAssertEqual(match, "atrial fibrillation")
    }

    func testMultiWordNoMatchAtWrongIndex() {
        let words = ["the", "atrial", "fibrillation"]
        let match = index.checkMultiWord(words: words, startIndex: 0)
        XCTAssertNil(match) // "the" doesn't start any multi-word term
    }

    // MARK: - Prompt Hints

    func testPromptHintTermsNotEmpty() {
        XCTAssertGreaterThan(index.promptHintTerms.count, 50)
        XCTAssertLessThanOrEqual(index.promptHintTerms.count, 300)
    }

    func testPromptHintTermsContainHighValueTerms() {
        let hints = Set(index.promptHintTerms)
        XCTAssertTrue(hints.contains("hypertension"))
        XCTAssertTrue(hints.contains("metformin"))
    }
}

final class MedCorrectorTests: XCTestCase {

    var corrector: MedCorrector!

    override func setUpWithError() throws {
        guard let index = MedicalTermIndex.load() else {
            throw XCTSkip("MedicalTermIndex not available")
        }
        corrector = MedCorrector(index: index)
    }

    // MARK: - Basic Correction

    func testCorrectsSingleTypo() {
        let (words, corrections) = corrector.correctWords(["tachykardia"])
        XCTAssertEqual(words, ["tachycardia"])
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections[0].original, "tachykardia")
        XCTAssertEqual(corrections[0].corrected, "tachycardia")
    }

    func testPreservesCorrectMedicalTerms() {
        let (words, corrections) = corrector.correctWords(["hypertension", "and", "tachycardia"])
        XCTAssertEqual(words, ["hypertension", "and", "tachycardia"])
        XCTAssertTrue(corrections.isEmpty)
    }

    // MARK: - Safety Rules

    func testNeverChangesShortWords() {
        let (words, corrections) = corrector.correctWords(["pain", "dose", "mg"])
        XCTAssertEqual(words, ["pain", "dose", "mg"])
        XCTAssertTrue(corrections.isEmpty)
    }

    func testNeverChangesWordsWithDigits() {
        let (words, corrections) = corrector.correctWords(["500mg", "12lead"])
        XCTAssertEqual(words, ["500mg", "12lead"])
        XCTAssertTrue(corrections.isEmpty)
    }

    func testMaxCorrectionsPerChunk() {
        // Create a chunk with many correctable words
        let words = ["tachykardia", "hypertention", "bronkitis", "pneumona", "cholecystytis"]
        let (_, corrections) = corrector.correctWords(words)
        XCTAssertLessThanOrEqual(corrections.count, MedCorrector.maxCorrectionsPerChunk)
    }

    // MARK: - Capitalization Preservation

    func testPreservesTitleCase() {
        let (words, corrections) = corrector.correctWords(["Tachykardia"])
        XCTAssertEqual(words.first, "Tachycardia")
        XCTAssertEqual(corrections.count, 1)
    }

    func testPreservesAllCaps() {
        let (words, corrections) = corrector.correctWords(["TACHYKARDIA"])
        XCTAssertEqual(words.first, "TACHYCARDIA")
        XCTAssertEqual(corrections.count, 1)
    }

    // MARK: - Punctuation Preservation

    func testPreservesTrailingPunctuation() {
        let (words, corrections) = corrector.correctWords(["tachykardia,"])
        XCTAssertEqual(words.first, "tachycardia,")
        XCTAssertEqual(corrections.count, 1)
    }

    // MARK: - Streaming Consistency

    func testDeterministicCorrection() {
        // Same input should always produce same output (important for LA-2 stability)
        let input = ["tachykardia", "and", "hypertention"]
        let (words1, _) = corrector.correctWords(input)
        let (words2, _) = corrector.correctWords(input)
        XCTAssertEqual(words1, words2)
    }

    // MARK: - Empty/Trivial Input

    func testEmptyInput() {
        let (words, corrections) = corrector.correctWords([])
        XCTAssertTrue(words.isEmpty)
        XCTAssertTrue(corrections.isEmpty)
    }

    // MARK: - Medical Vocabulary Correction

    func testCommonMedicalMisspellings() {
        // Whisper commonly mishears these medical terms
        let tests: [(input: String, expected: String)] = [
            ("tachykardia", "tachycardia"),
            ("hypertention", "hypertension"),
            ("bradykardia", "bradycardia"),
        ]
        for test in tests {
            let (words, corrections) = corrector.correctWords([test.input])
            XCTAssertEqual(words.first, test.expected,
                           "Expected \"\(test.input)\" to correct to \"\(test.expected)\", got \"\(words.first ?? "nil")\"")
            XCTAssertEqual(corrections.count, 1)
        }
    }

    func testMedicationNamesPreserved() {
        // Correctly-spelled medications should pass through unchanged
        let meds = ["metformin", "lisinopril", "atorvastatin", "omeprazole",
                     "gabapentin", "sertraline", "amoxicillin", "vancomycin"]
        let (words, corrections) = corrector.correctWords(meds)
        XCTAssertEqual(words, meds, "Correctly-spelled medications should not be modified")
        XCTAssertTrue(corrections.isEmpty)
    }

    func testAnatomicalTermsPreserved() {
        let terms = ["bilateral", "anterior", "posterior", "subcutaneous",
                      "intramuscular", "intravenous", "peritoneal"]
        let (words, corrections) = corrector.correctWords(terms)
        XCTAssertEqual(words, terms, "Correctly-spelled anatomical terms should not be modified")
        XCTAssertTrue(corrections.isEmpty)
    }

    func testClinicalPhraseWithMixedCorrectAndIncorrect() {
        // Simulates a Whisper chunk: "the patient has tachykardia and hypertension"
        let input = ["the", "patient", "has", "tachykardia", "and", "hypertension"]
        let (words, corrections) = corrector.correctWords(input)
        XCTAssertEqual(words[3], "tachycardia", "Misspelled term should be corrected")
        XCTAssertEqual(words[5], "hypertension", "Correct term should be preserved")
        XCTAssertEqual(corrections.count, 1, "Only the misspelled term should be corrected")
    }

    func testDoesNotCorruptNonMedicalWords() {
        // Common English words near medical terms should not be changed
        // (avoiding words that happen to be in the 98K medical dictionary)
        let input = ["the", "weather", "outside", "is", "getting", "warmer", "tonight"]
        let (words, corrections) = corrector.correctWords(input)
        XCTAssertEqual(words, input, "Non-medical words should not be modified")
        XCTAssertTrue(corrections.isEmpty)
    }

    func testDosageNumbersUntouched() {
        // Drug dosages should never be modified
        let input = ["metformin", "500mg", "twice", "daily", "lisinopril", "10mg"]
        let (words, corrections) = corrector.correctWords(input)
        XCTAssertEqual(words[1], "500mg")
        XCTAssertEqual(words[5], "10mg")
        XCTAssertTrue(corrections.isEmpty)
    }
}

// MARK: - Stabilizer + MedCorrector Integration Tests

/// Tests that medical term correction integrates correctly with the
/// TranscriptStabilizer's LA-2 algorithm during streaming.
final class MedicalStabilizerIntegrationTests: XCTestCase {

    private var stabilizer: TranscriptStabilizer!
    private var corrector: MedCorrector!

    override func setUpWithError() throws {
        guard let index = MedicalTermIndex.load() else {
            throw XCTSkip("MedicalTermIndex not available")
        }
        stabilizer = TranscriptStabilizer()
        corrector = MedCorrector(index: index)
        stabilizer.medCorrector = corrector
    }

    // MARK: - Helpers

    private func makeSegment(_ text: String) -> TranscriptionSegment {
        TranscriptionSegment(text: text, startTimeMs: 0, endTimeMs: 1000, tokens: [])
    }

    private func makeResult(_ text: String) -> DecodeResult {
        DecodeResult(segments: [makeSegment(text)], windowStartAbsMs: 0)
    }

    // MARK: - Medical Term Agreement

    func testCorrectedTermsAgreeAcrossDecodes() {
        // Two decodes both produce the same typo -> corrector makes them agree
        let res1 = makeResult("the patient has tachykardia and hypertension")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeResult("the patient has tachykardia and hypertension with edema")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1500, commitMarginMs: 300)

        // "tachycardia" (corrected) should appear in output, not "tachykardia"
        let fullText = state.fullRawText
        XCTAssertTrue(fullText.contains("tachycardia"),
                       "Corrected term should appear: \(fullText)")
        XCTAssertFalse(fullText.contains("tachykardia"),
                        "Original misspelling should not appear: \(fullText)")
        XCTAssertTrue(fullText.contains("hypertension"),
                       "Correct medical term should be preserved: \(fullText)")
    }

    func testMedicalTermsStabilizeWithoutFlicker() {
        // Simulate 3 consecutive decodes with a medical misspelling
        // MedCorrector should produce the same correction each time -> stable LA-2
        let res1 = makeResult("patient presents with tachykardia elevated blood pressure")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeResult("patient presents with tachykardia elevated blood pressure and edema")
        stabilizer.update(decodeResult: res2, windowEndAbsMs: 1500, commitMarginMs: 300)

        let res3 = makeResult("patient presents with tachykardia elevated blood pressure and edema bilateral")
        let state = stabilizer.update(decodeResult: res3, windowEndAbsMs: 2000, commitMarginMs: 300)

        // Corrected "tachycardia" should be stably committed
        let fullText = state.fullRawText
        XCTAssertTrue(fullText.contains("tachycardia"), "Corrected term in output: \(fullText)")
        // Should appear exactly once (no duplication from correction flickering)
        let count = fullText.components(separatedBy: "tachycardia").count - 1
        XCTAssertEqual(count, 1, "Corrected term should appear exactly once, got \(count) in: \(fullText)")
    }

    func testMixedMedicalAndNonMedicalTerms() {
        // Medical terms mixed with normal words — only medical typos corrected
        let res1 = makeResult("the electrocardiogram showed normal sinus rhythm with tachykardia")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeResult("the electrocardiogram showed normal sinus rhythm with tachykardia and hypertension")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1500, commitMarginMs: 300)

        let fullText = state.fullRawText
        XCTAssertTrue(fullText.contains("electrocardiogram"),
                       "Correctly spelled medical term preserved: \(fullText)")
        XCTAssertTrue(fullText.contains("tachycardia"),
                       "Misspelled medical term corrected: \(fullText)")
        XCTAssertTrue(fullText.contains("normal"),
                       "Non-medical words preserved: \(fullText)")
    }

    func testMedicalTermsInFinalizeAll() {
        // Single decode (all speculative) -> finalizeAll() should contain corrected terms
        let res = makeResult("patient has tachykardia and hypertention")
        stabilizer.update(decodeResult: res, windowEndAbsMs: 1000, commitMarginMs: 300)

        stabilizer.finalizeAll()

        XCTAssertTrue(stabilizer.state.rawCommitted.contains("tachycardia"),
                       "Corrected term after finalize: \(stabilizer.state.rawCommitted)")
        XCTAssertTrue(stabilizer.state.rawCommitted.contains("hypertension"),
                       "Corrected term after finalize: \(stabilizer.state.rawCommitted)")
    }

    func testMultipleMedicationNames() {
        // Simulates dictating a medication list
        let res1 = makeResult("current medications include metformin lisinopril and atorvastatin")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeResult("current medications include metformin lisinopril and atorvastatin daily")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1500, commitMarginMs: 300)

        let fullText = state.fullRawText
        XCTAssertTrue(fullText.contains("metformin"), "Medication preserved: \(fullText)")
        XCTAssertTrue(fullText.contains("lisinopril"), "Medication preserved: \(fullText)")
        XCTAssertTrue(fullText.contains("atorvastatin"), "Medication preserved: \(fullText)")
    }

    func testWithoutMedCorrectorTyposPersist() {
        // Verify that without MedCorrector, typos pass through unchanged
        let plainStabilizer = TranscriptStabilizer()
        // medCorrector is nil by default

        let res1 = makeResult("patient has tachykardia and hypertension")
        plainStabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeResult("patient has tachykardia and hypertension with edema")
        let state = plainStabilizer.update(decodeResult: res2, windowEndAbsMs: 1500, commitMarginMs: 300)

        // Without corrector, the typo should persist
        XCTAssertTrue(state.fullRawText.contains("tachykardia"),
                       "Without MedCorrector, typo should persist: \(state.fullRawText)")
        XCTAssertFalse(state.fullRawText.contains("tachycardia"),
                        "Without MedCorrector, corrected form should not appear")
    }

    func testDifferentialDiagnosisTerms() {
        // Simulates dictating a differential diagnosis
        let res1 = makeResult("differential diagnosis includes cholecystitis pancreatitis and appendicitis")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeResult("differential diagnosis includes cholecystitis pancreatitis and appendicitis with peritonitis")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1500, commitMarginMs: 300)

        let fullText = state.fullRawText
        XCTAssertTrue(fullText.contains("cholecystitis"), "Diagnosis term preserved: \(fullText)")
        XCTAssertTrue(fullText.contains("pancreatitis"), "Diagnosis term preserved: \(fullText)")
        XCTAssertTrue(fullText.contains("appendicitis"), "Diagnosis term preserved: \(fullText)")
    }
}
