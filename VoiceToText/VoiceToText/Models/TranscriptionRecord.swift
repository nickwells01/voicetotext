import Foundation

// MARK: - Transcription Record

struct TranscriptionRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let rawText: String
    let processedText: String?
    let durationSeconds: TimeInterval
    let modelName: String
    let language: String

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        rawText: String,
        processedText: String? = nil,
        durationSeconds: TimeInterval,
        modelName: String,
        language: String = "en"
    ) {
        self.id = id
        self.date = date
        self.rawText = rawText
        self.processedText = processedText
        self.durationSeconds = durationSeconds
        self.modelName = modelName
        self.language = language
    }

    /// The best available text (processed if available, otherwise raw)
    var displayText: String {
        processedText ?? rawText
    }
}
