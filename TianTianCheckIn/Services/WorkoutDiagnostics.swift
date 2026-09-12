@preconcurrency import AVFoundation
import CoreImage
import Foundation
import UIKit

/// An opt-in, local-only capture of the exact inputs used by automatic counting.
/// The folder can be copied from the app container when the phone is next connected.
final class WorkoutDiagnosticsRecorder: @unchecked Sendable {
    struct Manifest: Codable {
        let sessionID: UUID
        let startedAt: Date
        let appVersion: String
        let device: String
        let systemVersion: String
        let config: WorkoutConfig
        var finishedAt: Date?
        var state: String
        var error: String?
    }

    private struct PoseLine: Codable {
        struct Joint: Codable {
            let name: String
            let x: Double
            let y: Double
            let confidence: Double
        }
        let uptime: TimeInterval
        let personCount: Int
        let selected: Bool
        let joints: [Joint]
    }

    private struct EventLine: Codable {
        let date: Date
        let uptime: TimeInterval
        let kind: String
        let detail: String?
    }

    static let folderName = "TianTianCheckInDiagnostics"
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    static let maximumSessionCount = 3

    let sessionID = UUID()
    let sessionURL: URL
    private let queue = DispatchQueue(label: "com.tiantiandaka.diagnostics", qos: .utility)
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var manifest: Manifest
    private var poseHandle: FileHandle?
    private var eventHandle: FileHandle?
    private var lastFrameUptime = -Double.infinity
    private var isFinished = false

    init(config: WorkoutConfig, baseDirectory: URL? = nil) {
        let support = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = support.appendingPathComponent(Self.folderName, isDirectory: true)
        sessionURL = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        manifest = Manifest(
            sessionID: sessionID,
            startedAt: Date(),
            appVersion: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))",
            device: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            config: config,
            finishedAt: nil,
            state: "recording",
            error: nil
        )
        encoder.dateEncodingStrategy = .iso8601
        try? fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableSessionURL = sessionURL
        try? mutableSessionURL.setResourceValues(values)
        let poseURL = sessionURL.appendingPathComponent("pose.ndjson")
        let eventURL = sessionURL.appendingPathComponent("events.ndjson")
        fileManager.createFile(atPath: poseURL.path, contents: nil)
        fileManager.createFile(atPath: eventURL.path, contents: nil)
        poseHandle = try? FileHandle(forWritingTo: poseURL)
        eventHandle = try? FileHandle(forWritingTo: eventURL)
        writeManifest()
        Self.cleanup(baseDirectory: baseDirectory)
    }

    func recordEvent(_ kind: String, detail: String? = nil, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        queue.async { [weak self] in
            guard let self, !isFinished else { return }
            append(EventLine(date: Date(), uptime: uptime, kind: kind, detail: detail), to: eventHandle)
        }
    }

    func recordPose(samples: [BodyPoseSample], selected: BodyPoseSample?) {
        queue.async { [weak self] in
            guard let self, !isFinished else { return }
            for sample in samples {
                let line = PoseLine(
                    uptime: sample.captureUptime,
                    personCount: sample.personCount,
                    selected: selected?.captureUptime == sample.captureUptime && selected?.points == sample.points,
                    joints: sample.points.map {
                        PoseLine.Joint(name: $0.key.rawValue, x: $0.value.x, y: $0.value.y, confidence: $0.value.confidence)
                    }.sorted { $0.name < $1.name }
                )
                append(line, to: poseHandle)
            }
        }
    }

    func captureFrame(_ sampleBuffer: CMSampleBuffer) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastFrameUptime >= 1 else { return }
        lastFrameUptime = uptime
        let retainedBuffer = DiagnosticSampleBuffer(sampleBuffer)
        queue.async { [weak self] in
            guard let self, !isFinished,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(retainedBuffer.value) else { return }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let extent = image.extent
            let scale = min(1, 480 / max(extent.width, extent.height))
            let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cgImage = ciContext.createCGImage(resized, from: resized.extent),
                  let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.65) else { return }
            let name = String(format: "frame-%.3f.jpg", uptime)
            try? data.write(to: sessionURL.appendingPathComponent(name), options: .atomic)
        }
    }

    func attachVideo(from url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                defer { continuation.resume() }
                guard let self else { return }
                let destination = sessionURL.appendingPathComponent("video.mov")
                try? fileManager.removeItem(at: destination)
                try? fileManager.copyItem(at: url, to: destination)
            }
        }
    }

    func finish(state: String, error: String? = nil) {
        queue.async { [self] in
            guard !isFinished else { return }
            manifest.finishedAt = Date()
            manifest.state = state
            manifest.error = error
            writeManifest()
            try? poseHandle?.close()
            try? eventHandle?.close()
            poseHandle = nil
            eventHandle = nil
            isFinished = true
        }
    }

    static func deleteAll(baseDirectory: URL? = nil) {
        let root = diagnosticsRoot(baseDirectory: baseDirectory)
        try? FileManager.default.removeItem(at: root)
    }

    static func cleanup(baseDirectory: URL? = nil, now: Date = Date()) {
        let manager = FileManager.default
        let root = diagnosticsRoot(baseDirectory: baseDirectory)
        guard let folders = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessions = folders.map { folder -> (URL, Date) in
            let manifestURL = folder.appendingPathComponent("manifest.json")
            let startedAt = (try? Data(contentsOf: manifestURL))
                .flatMap { try? decoder.decode(Manifest.self, from: $0) }
                .map(\.startedAt) ?? .distantPast
            return (folder, startedAt)
        }
        let sorted = sessions.sorted { $0.1 > $1.1 }
        for (index, session) in sorted.enumerated() {
            let (folder, created) = session
            if index >= maximumSessionCount || now.timeIntervalSince(created) > retentionInterval {
                try? manager.removeItem(at: folder)
            }
        }
    }

    private static func diagnosticsRoot(baseDirectory: URL?) -> URL {
        let support = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(folderName, isDirectory: true)
    }

    private func append<T: Encodable>(_ value: T, to handle: FileHandle?) {
        guard let handle, var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    private func writeManifest() {
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: sessionURL.appendingPathComponent("manifest.json"), options: .atomic)
    }
}

private final class DiagnosticSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
    init(_ value: CMSampleBuffer) { self.value = value }
}
