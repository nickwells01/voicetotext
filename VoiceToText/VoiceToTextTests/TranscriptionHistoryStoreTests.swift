import XCTest
@testable import VoiceToText

final class TranscriptionHistoryStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test_history_\(UUID().uuidString).json")
    }

    private func makeRecord(rawText: String, processedText: String? = nil) -> TranscriptionRecord {
        TranscriptionRecord(rawText: rawText, processedText: processedText, durationSeconds: 5.0, modelName: "test-model")
    }

    // MARK: - Add Record

    @MainActor
    func testAddRecordInsertsAtFront() {
        let store = TranscriptionHistoryStore(fileURL: makeTempFileURL())

        let first = makeRecord(rawText: "first")
        let second = makeRecord(rawText: "second")

        store.addRecord(first)
        store.addRecord(second)

        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.records[0].rawText, "second")
        XCTAssertEqual(store.records[1].rawText, "first")
    }

    // MARK: - Delete Record

    @MainActor
    func testDeleteRecordByID() {
        let store = TranscriptionHistoryStore(fileURL: makeTempFileURL())

        let keep = makeRecord(rawText: "keep me")
        let remove = makeRecord(rawText: "remove me")

        store.addRecord(keep)
        store.addRecord(remove)

        store.deleteRecord(remove)

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].id, keep.id)
        XCTAssertFalse(store.records.contains(where: { $0.id == remove.id }))
    }

    // MARK: - Clear All

    @MainActor
    func testClearAllEmptiesRecords() {
        let store = TranscriptionHistoryStore(fileURL: makeTempFileURL())

        store.addRecord(makeRecord(rawText: "one"))
        store.addRecord(makeRecord(rawText: "two"))
        store.addRecord(makeRecord(rawText: "three"))

        XCTAssertEqual(store.records.count, 3)

        store.clearAll()

        XCTAssertTrue(store.records.isEmpty)
    }

    // MARK: - Search

    @MainActor
    func testSearchByDisplayTextCaseInsensitive() {
        let store = TranscriptionHistoryStore(fileURL: makeTempFileURL())

        store.addRecord(makeRecord(rawText: "hello world"))
        store.addRecord(makeRecord(rawText: "goodbye moon"))

        let results = store.search(query: "HELLO")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].rawText, "hello world")
    }

    @MainActor
    func testSearchEmptyQueryReturnsAll() {
        let store = TranscriptionHistoryStore(fileURL: makeTempFileURL())

        store.addRecord(makeRecord(rawText: "alpha"))
        store.addRecord(makeRecord(rawText: "beta"))
        store.addRecord(makeRecord(rawText: "gamma"))

        let results = store.search(query: "")

        XCTAssertEqual(results.count, 3)
    }

    // MARK: - Persistence

    @MainActor
    func testPersistenceSurvivesSaveLoadCycle() {
        let fileURL = makeTempFileURL()

        let store1 = TranscriptionHistoryStore(fileURL: fileURL)
        store1.addRecord(makeRecord(rawText: "persisted one"))
        store1.addRecord(makeRecord(rawText: "persisted two"))

        // Create a new store pointing at the same file to verify persistence
        let store2 = TranscriptionHistoryStore(fileURL: fileURL)

        XCTAssertEqual(store2.records.count, 2)
        XCTAssertEqual(store2.records[0].rawText, "persisted two")
        XCTAssertEqual(store2.records[1].rawText, "persisted one")
    }
}
