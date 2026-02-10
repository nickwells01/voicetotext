import Foundation
import os

// MARK: - ModelManager Errors

enum ModelManagerError: LocalizedError {
    case downloadFailed(String)
    case invalidServerResponse

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        case .invalidServerResponse:
            return "Received an invalid response from the server."
        }
    }
}

// MARK: - Download Delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let modelId: String
    private let continuation: CheckedContinuation<URL, Error>
    private var lastProgressUpdate = Date.distantPast

    init(modelId: String, continuation: CheckedContinuation<URL, Error>) {
        self.modelId = modelId
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy to a stable temp location before the system deletes it
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("download")
        do {
            try FileManager.default.copyItem(at: location, to: tempCopy)
            continuation.resume(returning: tempCopy)
        } catch {
            continuation.resume(throwing: ModelManagerError.downloadFailed("Failed to copy downloaded file: \(error.localizedDescription)"))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) >= 0.1 else { return }
        lastProgressUpdate = now
        let progress = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0)
        let modelId = self.modelId
        Task { @MainActor in
            ModelManager.shared.downloadProgress[modelId] = progress
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            continuation.resume(throwing: ModelManagerError.downloadFailed(error.localizedDescription))
        }
    }
}

// MARK: - ModelManager

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "ModelManager")

    @Published var downloadProgress: [String: Double] = [:]
    @Published var isDownloading: [String: Bool] = [:]

    private let fileManager = FileManager.default

    // MARK: - Directory Setup

    private var modelsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("VoiceToText", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    init() {
        createModelsDirectoryIfNeeded()
    }

    private func createModelsDirectoryIfNeeded() {
        let url = modelsDirectory
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                logger.info("Created models directory at \(url.path)")
            } catch {
                logger.error("Failed to create models directory: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - File Paths

    func modelFileURL(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        fileManager.fileExists(atPath: modelFileURL(for: model).path)
    }

    // MARK: - Download

    func downloadModel(_ model: WhisperModel) async throws {
        guard isDownloading[model.id] != true else {
            logger.warning("Download already in progress for \(model.id)")
            return
        }

        logger.info("Starting download of model \(model.id) from \(model.downloadURL)")
        isDownloading[model.id] = true
        downloadProgress[model.id] = 0

        defer {
            isDownloading[model.id] = false
        }

        let tempFileURL: URL = try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                modelId: model.id,
                continuation: continuation
            )
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            let task = session.downloadTask(with: model.downloadURL)
            task.resume()
        }

        // Move downloaded file to final destination
        let destinationURL = modelFileURL(for: model)
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: tempFileURL, to: destinationURL)

        downloadProgress[model.id] = 1.0
        logger.info("Model \(model.id) downloaded successfully")
    }

    // MARK: - Delete

    func deleteModel(_ model: WhisperModel) throws {
        let url = modelFileURL(for: model)
        guard fileManager.fileExists(atPath: url.path) else {
            logger.warning("Attempted to delete model \(model.id) but file does not exist")
            return
        }

        try fileManager.removeItem(at: url)
        logger.info("Deleted model \(model.id)")
    }
}
