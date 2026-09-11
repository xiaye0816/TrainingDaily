@preconcurrency import AVFoundation
import Foundation
import UIKit

struct RecordingStart: Sendable {
    let url: URL
    let uptime: TimeInterval
}

struct CameraZoomOption: Identifiable, Equatable, Sendable {
    let label: String
    let deviceFactor: CGFloat

    var id: String { label }
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
    private let analysisOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configuredWithAudio = false
    private var configuredWithAnalysis = false
    private var poseAnalyzer: PoseRecognitionEngine?
    private var currentOrientation = UIDeviceOrientation.portrait
    private var currentURL: URL?
    private var startContinuation: CheckedContinuation<RecordingStart, Error>?
    private var stopContinuation: CheckedContinuation<URL, Error>?

    func prepare(includeAudio: Bool, poseAnalyzer: PoseRecognitionEngine? = nil) async throws {
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
                    try self.configure(includeAudio: includeAudio, poseAnalyzer: poseAnalyzer)
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
                self.currentOrientation = orientation
                self.configureVideoConnections()
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
                if self.session.isRunning {
                    self.session.stopRunning()
                }
            }
        }
    }

    func switchCamera() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self, let currentInput = self.videoInput else { return }
                let target: AVCaptureDevice.Position = currentInput.device.position == .back ? .front : .back
                guard let device = Self.preferredCamera(position: target) else {
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
                        self.applyDefaultOneTimesZoom(to: device)
                        self.configureVideoConnections()
                        self.poseAnalyzer?.resetForCameraChange()
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

    func availableZoomOptions() async -> [CameraZoomOption] {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                continuation.resume(returning: self?.resolvedZoomOptions() ?? [])
            }
        }
    }

    func setZoomFactor(_ factor: CGFloat) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let device = self?.videoInput?.device else {
                    continuation.resume()
                    return
                }
                do {
                    try device.lockForConfiguration()
                    let resolved = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                    device.videoZoomFactor = resolved
                    device.unlockForConfiguration()
                } catch {
                    // Keep the previous zoom if the camera is being reconfigured.
                }
                continuation.resume()
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func updateOrientation(_ orientation: UIDeviceOrientation) {
        guard orientation == .portrait || orientation == .portraitUpsideDown
                || orientation == .landscapeLeft || orientation == .landscapeRight else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            currentOrientation = orientation
            configureVideoConnections()
        }
    }

    private func configure(includeAudio: Bool, poseAnalyzer: PoseRecognitionEngine?) throws {
        let includeAnalysis = poseAnalyzer != nil
        if !session.inputs.isEmpty,
           configuredWithAudio == includeAudio,
           configuredWithAnalysis == includeAnalysis {
            self.poseAnalyzer = poseAnalyzer
            if includeAnalysis {
                analysisOutput.setSampleBufferDelegate(poseAnalyzer, queue: poseAnalyzer?.captureQueue)
            }
            configureVideoConnections()
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        analysisOutput.setSampleBufferDelegate(nil, queue: nil)
        if session.outputs.contains(movieOutput) {
            session.removeOutput(movieOutput)
        }
        if session.outputs.contains(analysisOutput) {
            session.removeOutput(analysisOutput)
        }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        guard let camera = Self.preferredCamera(position: .back) else {
            throw CameraRecorderError.cameraUnavailable
        }
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(cameraInput) else { throw CameraRecorderError.cannotAddInput }
        session.addInput(cameraInput)
        videoInput = cameraInput
        configureDevice(camera)
        applyDefaultOneTimesZoom(to: camera)

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
        if let poseAnalyzer {
            analysisOutput.alwaysDiscardsLateVideoFrames = true
            analysisOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            guard session.canAddOutput(analysisOutput) else { throw CameraRecorderError.cannotAddOutput }
            session.addOutput(analysisOutput)
            analysisOutput.setSampleBufferDelegate(poseAnalyzer, queue: poseAnalyzer.captureQueue)
        }
        configuredWithAudio = includeAudio
        configuredWithAnalysis = includeAnalysis
        self.poseAnalyzer = poseAnalyzer
        configureVideoConnections()

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

    private static func preferredCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if position == .back {
            deviceTypes = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        } else {
            deviceTypes = [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        }
        for type in deviceTypes {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return nil
    }

    private func applyDefaultOneTimesZoom(to device: AVCaptureDevice) {
        guard let oneTimes = resolvedZoomOptions().first(where: { $0.label == "1×" }) else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(max(oneTimes.deviceFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        } catch {
            // The default hardware factor remains usable.
        }
    }

    private func resolvedZoomOptions() -> [CameraZoomOption] {
        guard let device = videoInput?.device else { return [] }
        let minimum = device.minAvailableVideoZoomFactor
        let maximum = device.maxAvailableVideoZoomFactor
        let switchFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
        let hasUltraWide = device.position == .back
            && (device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera)
        let oneTimesFactor: CGFloat = hasUltraWide ? CGFloat(switchFactors.first ?? 2) : max(1, minimum)

        var candidates: [CameraZoomOption] = []
        if hasUltraWide, minimum <= oneTimesFactor * 0.55 {
            candidates.append(CameraZoomOption(label: "0.5×", deviceFactor: minimum))
        }
        candidates.append(CameraZoomOption(label: "1×", deviceFactor: min(oneTimesFactor, maximum)))
        if maximum >= oneTimesFactor * 1.8 {
            candidates.append(CameraZoomOption(label: "2×", deviceFactor: min(oneTimesFactor * 2, maximum)))
        }
        return candidates.reduce(into: []) { result, candidate in
            guard !result.contains(where: { abs($0.deviceFactor - candidate.deviceFactor) < 0.01 }) else { return }
            result.append(candidate)
        }
    }

    private func configureVideoConnections() {
        let angle = Self.rotationAngle(for: currentOrientation)
        let isFrontCamera = videoInput?.device.position == .front
        for output in [movieOutput as AVCaptureOutput, analysisOutput as AVCaptureOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isFrontCamera
            }
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
