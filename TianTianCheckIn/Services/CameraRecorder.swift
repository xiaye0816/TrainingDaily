@preconcurrency import AVFoundation
import Foundation
import UIKit

struct RecordingStart: Sendable {
    let url: URL
    let uptime: TimeInterval
}

enum CameraRecorderError: LocalizedError {
    case cameraPermissionDenied
    case microphonePermissionDenied
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case recordingDidNotStart
    case recordingFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied: "请在系统设置中允许使用摄像头。"
        case .microphonePermissionDenied: "请在系统设置中允许使用麦克风，或关闭现场声音。"
        case .cameraUnavailable: "当前设备没有可用摄像头。"
        case .cannotAddInput: "无法连接摄像头或麦克风。"
        case .cannotAddOutput: "无法创建录像输出。"
        case .recordingDidNotStart: "录像未能启动，请重试。"
        case let .recordingFailed(error): error?.localizedDescription ?? "录像失败，请重试。"
        }
    }
}

final class CameraRecorder: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.tiantiandaka.capture-session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configuredWithAudio = false
    private var currentURL: URL?
    private var startContinuation: CheckedContinuation<RecordingStart, Error>?
    private var stopContinuation: CheckedContinuation<URL, Error>?

    func prepare(includeAudio: Bool) async throws {
        guard await Self.requestAccess(for: .video) else {
            throw CameraRecorderError.cameraPermissionDenied
        }
        if includeAudio, !(await Self.requestAccess(for: .audio)) {
            throw CameraRecorderError.microphonePermissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.configure(includeAudio: includeAudio)
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startRecording(orientation: UIDeviceOrientation) async throws -> RecordingStart {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecordingStart, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                guard !self.movieOutput.isRecording else {
                    continuation.resume(throwing: CameraRecorderError.recordingDidNotStart)
                    return
                }

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tiantiandaka-raw-\(UUID().uuidString)")
                    .appendingPathExtension("mov")
                self.currentURL = url
                self.startContinuation = continuation

                if let connection = self.movieOutput.connection(with: .video) {
                    let angle = Self.rotationAngle(for: orientation)
                    if connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                }
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                guard self.movieOutput.isRecording else {
                    if let url = self.currentURL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: CameraRecorderError.recordingDidNotStart)
                    }
                    return
                }
                self.stopContinuation = continuation
                self.movieOutput.stopRecording()
            }
        }
    }

    func switchCamera() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self, let currentInput = self.videoInput else { return }
                let target: AVCaptureDevice.Position = currentInput.device.position == .back ? .front : .back
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: target) else {
                    continuation.resume(throwing: CameraRecorderError.cameraUnavailable)
                    return
                }
                do {
                    let replacement = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()
                    self.session.removeInput(currentInput)
                    if self.session.canAddInput(replacement) {
                        self.session.addInput(replacement)
                        self.videoInput = replacement
                        self.configureDevice(device)
                        self.session.commitConfiguration()
                        continuation.resume()
                    } else {
                        self.session.addInput(currentInput)
                        self.session.commitConfiguration()
                        continuation.resume(throwing: CameraRecorderError.cannotAddInput)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configure(includeAudio: Bool) throws {
        if !session.inputs.isEmpty, configuredWithAudio == includeAudio { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        if session.outputs.contains(movieOutput) {
            session.removeOutput(movieOutput)
        }

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraRecorderError.cameraUnavailable
        }
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(cameraInput) else { throw CameraRecorderError.cannotAddInput }
        session.addInput(cameraInput)
        videoInput = cameraInput
        configureDevice(camera)

        if includeAudio {
            guard let microphone = AVCaptureDevice.default(for: .audio) else {
                throw CameraRecorderError.cannotAddInput
            }
            let microphoneInput = try AVCaptureDeviceInput(device: microphone)
            guard session.canAddInput(microphoneInput) else { throw CameraRecorderError.cannotAddInput }
            session.addInput(microphoneInput)
        }

        guard session.canAddOutput(movieOutput) else { throw CameraRecorderError.cannotAddOutput }
        session.addOutput(movieOutput)
        configuredWithAudio = includeAudio

        let audioSession = AVAudioSession.sharedInstance()
        if includeAudio {
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        } else {
            try audioSession.setCategory(.playback, mode: .spokenAudio)
        }
        try audioSession.setActive(true)
    }

    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.automaticallyAdjustsVideoHDREnabled = false
            if device.activeFormat.isVideoHDRSupported {
                device.isVideoHDREnabled = false
            }
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
        } catch {
            // Keep the device defaults when a format can't be locked.
        }
    }

    private static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: true
        case .notDetermined:
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default: false
        }
    }

    private static func rotationAngle(for orientation: UIDeviceOrientation) -> CGFloat {
        switch orientation {
        case .landscapeLeft: 0
        case .landscapeRight: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        startContinuation?.resume(
            returning: RecordingStart(url: fileURL, uptime: ProcessInfo.processInfo.systemUptime)
        )
        startContinuation = nil
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        if let error {
            let nsError = error as NSError
            let completed = nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
            if !completed {
                startContinuation?.resume(throwing: CameraRecorderError.recordingFailed(error))
                startContinuation = nil
                stopContinuation?.resume(throwing: CameraRecorderError.recordingFailed(error))
                stopContinuation = nil
                return
            }
        }
        stopContinuation?.resume(returning: outputFileURL)
        stopContinuation = nil
    }
}
