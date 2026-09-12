import Combine
import Foundation

enum WorkoutVideoState: String, Codable, Sendable {
    case processing
    case ready
    case failed
    case expired
}

struct WorkoutRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let exercise: ExerciseType
    let duration: TimeInterval
    let recordedDuration: TimeInterval?
    let recordingPipelineVersion: Int?
    let count: Int
    let endReason: WorkoutEndReason
    var videoState: WorkoutVideoState
    var videoFilename: String?
    var sourceVideoFilename: String?
    var processingConfig: WorkoutConfig?
    var processingEvents: [WorkoutEvent]?
    var errorMessage: String?
    var savedToPhotos: Bool
}

@MainActor
final class WorkoutHistoryStore: ObservableObject {
    static let shared = WorkoutHistoryStore()
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var records: [WorkoutRecord] = []

    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let indexURL: URL
    private var activeProcessingIDs: Set<UUID> = []

    init(baseDirectory: URL? = nil) {
        let applicationSupport = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directoryURL = applicationSupport.appendingPathComponent("TianTianCheckInHistory", isDirectory: true)
        indexURL = directoryURL.appendingPathComponent("records.json")
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        load()
        removeExpiredVideos(now: Date())
        let interruptedRealtimeIDs = records.filter {
            $0.videoState == .processing && $0.sourceVideoFilename == nil
        }.map(\.id)
        for id in interruptedRealtimeIDs {
            markFailed(id, message: "App 在生成视频时被中断，成绩已保留。")
        }
        let interruptedIDs = records.filter {
            $0.videoState == .processing && $0.sourceVideoFilename != nil
        }.map(\.id)
        Task { [weak self] in
            guard let self else { return }
            for id in interruptedIDs { await self.processVideo(id) }
        }
    }

    func beginVideoProcessing(
        rawURL: URL,
        startedAt: Date,
        duration: TimeInterval,
        count: Int,
        reason: WorkoutEndReason,
        config: WorkoutConfig,
        events: [WorkoutEvent]
    ) throws -> WorkoutRecord {
        let id = UUID()
        let sourceFilename = "source-\(id.uuidString).mov"
        let sourceURL = directoryURL.appendingPathComponent(sourceFilename)
        if fileManager.fileExists(atPath: sourceURL.path) {
            try fileManager.removeItem(at: sourceURL)
        }
        try fileManager.moveItem(at: rawURL, to: sourceURL)
        let record = WorkoutRecord(
            id: id,
            startedAt: startedAt,
            exercise: config.exerciseType,
            duration: duration,
            recordedDuration: duration,
            recordingPipelineVersion: 1,
            count: count,
            endReason: reason,
            videoState: .processing,
            videoFilename: nil,
            sourceVideoFilename: sourceFilename,
            processingConfig: config,
            processingEvents: events,
            errorMessage: nil,
            savedToPhotos: false
        )
        records.insert(record, at: 0)
        persist()
        return record
    }

    func addReadyVideo(
        videoURL: URL,
        startedAt: Date,
        duration: TimeInterval,
        recordedDuration: TimeInterval,
        count: Int,
        reason: WorkoutEndReason,
        config: WorkoutConfig
    ) throws -> WorkoutRecord {
        let id = UUID()
        let filename = "workout-\(id.uuidString).mov"
        let destination = directoryURL.appendingPathComponent(filename)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: videoURL, to: destination)
        let record = WorkoutRecord(
            id: id,
            startedAt: startedAt,
            exercise: config.exerciseType,
            duration: duration,
            recordedDuration: recordedDuration,
            recordingPipelineVersion: 2,
            count: count,
            endReason: reason,
            videoState: .ready,
            videoFilename: filename,
            sourceVideoFilename: nil,
            processingConfig: nil,
            processingEvents: nil,
            errorMessage: nil,
            savedToPhotos: false
        )
        records.insert(record, at: 0)
        persist()
        return record
    }

    /// Saves the result immediately, before the camera writer has finished.
    /// Completion updates this same record so a crash can never lose the score.
    func beginRealtimeVideoFinalization(
        startedAt: Date,
        duration: TimeInterval,
        count: Int,
        reason: WorkoutEndReason,
        config: WorkoutConfig
    ) -> WorkoutRecord {
        let record = WorkoutRecord(
            id: UUID(), startedAt: startedAt, exercise: config.exerciseType,
            duration: duration, recordedDuration: duration, recordingPipelineVersion: 3,
            count: count, endReason: reason,
            videoState: .processing, videoFilename: nil, sourceVideoFilename: nil,
            processingConfig: nil, processingEvents: nil,
            errorMessage: nil, savedToPhotos: false
        )
        records.insert(record, at: 0)
        persist()
        return record
    }

    func completeRealtimeVideo(_ id: UUID, videoURL: URL) throws -> WorkoutRecord {
        let filename = "workout-\(id.uuidString).mov"
        let destination = directoryURL.appendingPathComponent(filename)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: videoURL, to: destination)
        update(id) {
            $0.videoState = .ready
            $0.videoFilename = filename
            $0.errorMessage = nil
        }
        guard let record = records.first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return record
    }

    func failRealtimeVideo(_ id: UUID, message: String) {
        markFailed(id, message: message)
    }

    func addWithoutVideo(
        startedAt: Date,
        duration: TimeInterval,
        count: Int,
        reason: WorkoutEndReason,
        config: WorkoutConfig
    ) -> WorkoutRecord {
        let record = WorkoutRecord(
            id: UUID(), startedAt: startedAt, exercise: config.exerciseType,
            duration: duration, recordedDuration: nil, recordingPipelineVersion: nil,
            count: count, endReason: reason,
            videoState: .expired, videoFilename: nil, sourceVideoFilename: nil,
            processingConfig: nil, processingEvents: nil,
            errorMessage: nil, savedToPhotos: false
        )
        records.insert(record, at: 0)
        persist()
        return record
    }

    func addFailedVideo(
        startedAt: Date,
        duration: TimeInterval,
        recordedDuration: TimeInterval,
        count: Int,
        reason: WorkoutEndReason,
        config: WorkoutConfig,
        message: String
    ) -> WorkoutRecord {
        let record = WorkoutRecord(
            id: UUID(), startedAt: startedAt, exercise: config.exerciseType,
            duration: duration, recordedDuration: recordedDuration, recordingPipelineVersion: 2,
            count: count, endReason: reason,
            videoState: .failed, videoFilename: nil, sourceVideoFilename: nil,
            processingConfig: nil, processingEvents: nil,
            errorMessage: message, savedToPhotos: false
        )
        records.insert(record, at: 0)
        persist()
        return record
    }

    func videoURL(for record: WorkoutRecord) -> URL? {
        guard let filename = record.videoFilename else { return nil }
        let url = directoryURL.appendingPathComponent(filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func markSavedToPhotos(_ id: UUID) {
        update(id) { $0.savedToPhotos = true }
    }

    func delete(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        [record.videoFilename, record.sourceVideoFilename].compactMap { $0 }.forEach {
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent($0))
        }
        records.removeAll { $0.id == id }
        persist()
    }

    func retry(_ id: UUID) {
        update(id) {
            guard $0.sourceVideoFilename != nil else { return }
            $0.videoState = .processing
            $0.errorMessage = nil
        }
        Task { [weak self] in await self?.processVideo(id) }
    }

    func resumePendingVideos() async {
        let pendingIDs = records.filter { $0.videoState == .processing }.map(\.id)
        for id in pendingIDs { await processVideo(id) }
    }

    func processVideo(_ id: UUID) async {
        guard activeProcessingIDs.insert(id).inserted else { return }
        defer { activeProcessingIDs.remove(id) }
        guard let record = records.first(where: { $0.id == id }),
              let sourceFilename = record.sourceVideoFilename,
              let config = record.processingConfig,
              let events = record.processingEvents else { return }
        let sourceURL = directoryURL.appendingPathComponent(sourceFilename)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            markFailed(id, message: "原始录像已丢失，无法重新生成。")
            return
        }
        do {
            let output = try await VideoComposer.compose(
                rawURL: sourceURL,
                trimStart: 0,
                actualDuration: record.duration,
                config: config,
                events: events
            )
            let filename = "workout-\(id.uuidString).mov"
            let destination = directoryURL.appendingPathComponent(filename)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: output, to: destination)
            try? fileManager.removeItem(at: sourceURL)
            update(id) {
                $0.videoState = .ready
                $0.videoFilename = filename
                $0.sourceVideoFilename = nil
                $0.processingConfig = nil
                $0.processingEvents = nil
                $0.errorMessage = nil
            }
        } catch {
            markFailed(id, message: error.localizedDescription)
        }
    }

    func removeExpiredVideos(now: Date) {
        var changed = false
        for index in records.indices where records[index].videoState == .ready
            && now.timeIntervalSince(records[index].startedAt) >= Self.retentionInterval {
            if let filename = records[index].videoFilename {
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent(filename))
            }
            records[index].videoState = .expired
            records[index].videoFilename = nil
            changed = true
        }
        if changed { persist() }
    }

    private func markFailed(_ id: UUID, message: String) {
        update(id) {
            $0.videoState = .failed
            $0.errorMessage = message
        }
    }

    private func update(_ id: UUID, mutation: (inout WorkoutRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutation(&records[index])
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([WorkoutRecord].self, from: data) else { return }
        records = decoded.sorted { $0.startedAt > $1.startedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
