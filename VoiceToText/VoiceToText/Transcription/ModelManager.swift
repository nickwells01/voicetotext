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
    private let progressKeyPath: ReferenceWritableKeyPath<ModelManager, [String: Double]>

    init(
        modelId: String,
        continuation: CheckedContinuation<URL, Error>,
        progressKeyPath: ReferenceWritableKeyPath<ModelManager, [String: Double]> = \.downloadProgress
    ) {
        self.modelId = modelId
        self.continuation = continuation
        self.progressKeyPath = progressKeyPath
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
        let keyPath = self.progressKeyPath
        Task { @MainActor in
            ModelManager.shared[keyPath: keyPath][modelId] = progress
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
    @Published var coreMLDownloadProgress: [String: Double] = [:]
    @Published var isCoreMLDownloading: [String: Bool] = [:]
    @Published var fastDownloadProgress: [String: Double] = [:]
    @Published var isFastDownloading: [String: Bool] = [:]

    private var activeTasks: [String: URLSessionDownloadTask] = [:]
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

    func fastModelFileURL(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.q5FileName)
    }

    func isFastModelDownloaded(_ model: WhisperModel) -> Bool {
        fileManager.fileExists(atPath: fastModelFileURL(for: model).path)
    }

    func activeModelFileURL(for model: WhisperModel, fastMode: Bool) -> URL {
        if fastMode && isFastModelDownloaded(model) {
            return fastModelFileURL(for: model)
        }
        return modelFileURL(for: model)
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
            self.activeTasks[model.id] = task
            task.resume()
        }
        activeTasks[model.id] = nil

        // Move downloaded file to final destination
        let destinationURL = modelFileURL(for: model)
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: tempFileURL, to: destinationURL)

        downloadProgress[model.id] = 1.0
        logger.info("Model \(model.id) downloaded successfully")
    }

    // MARK: - Fast Model (Q5) Download

    func downloadFastModel(_ model: WhisperModel) async throws {
        let fastKey = "\(model.id)-fast"
        guard isFastDownloading[fastKey] != true else {
            logger.warning("Fast model download already in progress for \(model.id)")
            return
        }

        logger.info("Starting fast model download for \(model.id) from \(model.q5DownloadURL)")
        isFastDownloading[fastKey] = true
        fastDownloadProgress[fastKey] = 0

        defer {
            isFastDownloading[fastKey] = false
        }

        let tempFileURL: URL = try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                modelId: fastKey,
                continuation: continuation,
                progressKeyPath: \.fastDownloadProgress
            )
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            let task = session.downloadTask(with: model.q5DownloadURL)
            self.activeTasks[fastKey] = task
            task.resume()
        }
        activeTasks[fastKey] = nil

        let destinationURL = fastModelFileURL(for: model)
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: tempFileURL, to: destinationURL)

        fastDownloadProgress[fastKey] = 1.0
        logger.info("Fast model \(model.id) downloaded successfully")
    }

    func deleteFastModel(_ model: WhisperModel) throws {
        let url = fastModelFileURL(for: model)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
        logger.info("Deleted fast model for \(model.id)")
    }

    // MARK: - CoreML Model

    func coreMLEncoderURL(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.coreMLEncoderName, isDirectory: true)
    }

    func isCoreMLDownloaded(_ model: WhisperModel) -> Bool {
        fileManager.fileExists(atPath: coreMLEncoderURL(for: model).path)
    }

    func downloadCoreMLModel(for model: WhisperModel) async throws {
        guard let coreMLURL = model.coreMLModelURL else {
            logger.warning("No CoreML URL for model \(model.id)")
            return
        }

        let coreMLKey = "\(model.id)-coreml"
        guard isCoreMLDownloading[coreMLKey] != true else {
            logger.warning("CoreML download already in progress for \(model.id)")
            return
        }

        logger.info("Starting CoreML download for \(model.id)")
        isCoreMLDownloading[coreMLKey] = true
        coreMLDownloadProgress[coreMLKey] = 0

        defer {
            isCoreMLDownloading[coreMLKey] = false
        }

        // Download the zip file
        let tempZipURL: URL = try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                modelId: coreMLKey,
                continuation: continuation,
                progressKeyPath: \.coreMLDownloadProgress
            )
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            let task = session.downloadTask(with: coreMLURL)
            self.activeTasks[coreMLKey] = task
            task.resume()
        }
        activeTasks[coreMLKey] = nil

        // Extract zip to models directory
        let destinationURL = coreMLEncoderURL(for: model)
        try? fileManager.removeItem(at: destinationURL)

        // Use /usr/bin/ditto to extract (handles macOS zip format correctly)
        let tempExtractDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempExtractDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", tempZipURL.path, tempExtractDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ModelManagerError.downloadFailed("Failed to extract CoreML model zip")
        }

        // Find the .mlmodelc directory inside the extracted content
        let extractedContents = try fileManager.contentsOfDirectory(at: tempExtractDir, includingPropertiesForKeys: nil)
        if let mlmodelcDir = extractedContents.first(where: { $0.lastPathComponent.hasSuffix(".mlmodelc") }) {
            try fileManager.moveItem(at: mlmodelcDir, to: destinationURL)
        } else {
            // The zip might extract directly as the directory name we need
            // Try moving the whole extracted directory
            throw ModelManagerError.downloadFailed("Could not find .mlmodelc directory in extracted zip")
        }

        try? fileManager.removeItem(at: tempZipURL)
        coreMLDownloadProgress[coreMLKey] = 1.0
        logger.info("CoreML model for \(model.id) downloaded and extracted successfully")
    }

    func deleteCoreMLModel(_ model: WhisperModel) throws {
        let url = coreMLEncoderURL(for: model)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
        logger.info("Deleted CoreML model for \(model.id)")
    }

    // MARK: - Cancel Download

    func cancelDownload(key: String) {
        activeTasks[key]?.cancel()
        activeTasks[key] = nil
        isDownloading[key] = false
        downloadProgress[key] = nil
        let fastKey = "\(key)-fast"
        isFastDownloading[fastKey] = false
        fastDownloadProgress[fastKey] = nil
        let coreMLKey = "\(key)-coreml"
        isCoreMLDownloading[coreMLKey] = false
        coreMLDownloadProgress[coreMLKey] = nil
        logger.info("Cancelled download for key: \(key)")
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
