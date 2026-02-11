import Foundation
import os

// MARK: - Transcription History Store

@MainActor
final class TranscriptionHistoryStore: ObservableObject {
    static let shared = TranscriptionHistoryStore()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "HistoryStore")

    @Published var records: [TranscriptionRecord] = []

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VoiceToText", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        loadFromDisk()
    }

    // MARK: - Add Record

    func addRecord(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        saveToDisk()
        logger.info("Saved transcription record (\(record.displayText.prefix(40)))")
    }

    // MARK: - Delete

    func deleteRecord(_ record: TranscriptionRecord) {
        records.removeAll { $0.id == record.id }
        saveToDisk()
    }

    func clearAll() {
        records.removeAll()
        saveToDisk()
    }

    // MARK: - Search

    func search(query: String) -> [TranscriptionRecord] {
        guard !query.isEmpty else { return records }
        let lowered = query.lowercased()
        return records.filter {
            $0.displayText.lowercased().contains(lowered) ||
            $0.rawText.lowercased().contains(lowered)
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try JSONDecoder().decode([TranscriptionRecord].self, from: data)
            logger.info("Loaded \(self.records.count) history records")
        } catch {
            logger.error("Failed to load history: \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL)
        } catch {
            logger.error("Failed to save history: \(error.localizedDescription)")
        }
    }
}
