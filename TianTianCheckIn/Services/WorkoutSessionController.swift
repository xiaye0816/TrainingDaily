import Foundation
import UIKit

enum WorkoutPhase: Equatable {
    case idle
    case preparingCamera
    case framing
    case countdown(Int)
    case active
    case processing
    case result
    case failed
}

@MainActor
final class WorkoutSessionController: ObservableObject {
    @Published private(set) var phase: WorkoutPhase = .idle
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var count = 0
    @Published private(set) var result: WorkoutResult?
    @Published private(set) var isSaved = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var poseStatus: PoseTrackingStatus = .inactive
    @Published private(set) var isAutomaticCountingActive = false

    let cameraRecorder = CameraRecorder()

    private let speech = SpeechCoordinator()
    private let poseRecognition = PoseRecognitionEngine()
    private var config = WorkoutConfig.default
    private var events: [WorkoutEvent] = []
    private var clockTask: Task<Void, Never>?
    private var activeStartUptime: TimeInterval?
    private var rawStartUptime: TimeInterval?
    private var rawURL: URL?
    private var announcedSeconds: Set<Int> = []
    private var lastCountEventOffset: TimeInterval = 0
    private var isFinalizing = false

    var displayTime: String {
        if config.timerEnabled {
            return remainingSeconds.clockText
        }
        return elapsedSeconds.clockText
    }

    var currentConfig: WorkoutConfig { config }

    var canBeginCountdown: Bool {
        config.countingMode != .automatic || poseStatus.isReady
    }

    func prepare(config: WorkoutConfig) {
        resetSessionState()
        self.config = config.normalized
        remainingSeconds = self.config.durationSeconds
        phase = .preparingCamera
        let recognitionSessionID = UUID()
        self.recognitionSessionID = recognitionSessionID

        let analyzer: PoseRecognitionEngine?
        if self.config.countingMode == .automatic {
            poseStatus = .findingPerson
            analyzer = poseRecognition
            poseRecognition.configure(
                exercise: self.config.exerciseType,
                statusHandler: { [weak self] status in
                    Task { @MainActor [weak self] in
                        guard let self, self.recognitionSessionID == recognitionSessionID else { return }
                        self.handlePoseStatus(status)
                    }
                },
                detectionHandler: { [weak self] detection in
                    Task { @MainActor [weak self] in
                        guard let self, self.recognitionSessionID == recognitionSessionID else { return }
                        self.handleAutomaticDetection(detection)
                    }
                }
            )
        } else {
            poseStatus = .inactive
            analyzer = nil
            poseRecognition.stop()
        }

        Task {
            do {
                if self.config.recordingEnabled {
                    try await cameraRecorder.prepare(
                        includeAudio: self.config.microphoneEnabled,
                        poseAnalyzer: analyzer
                    )
                }
                phase = .framing
                cameraRecorder.updateOrientation(UIDevice.current.orientation)
            } catch {
                fail(error)
            }
        }
    }

    func beginCountdown(orientation: UIDeviceOrientation) {
        guard phase == .framing, canBeginCountdown else { return }

        Task {
            do {
                if config.countingMode == .automatic {
                    poseRecognition.pause()
                }
                if config.recordingEnabled {
                    let start = try await cameraRecorder.startRecording(orientation: orientation)
                    rawStartUptime = start.uptime
                    rawURL = start.url
                }

                for number in stride(from: 3, through: 1, by: -1) {
                    phase = .countdown(number)
                    speech.speakPriority("\(number)")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }

                let now = ProcessInfo.processInfo.systemUptime
                activeStartUptime = now
                elapsedSeconds = 0
                remainingSeconds = config.durationSeconds
                phase = .active
                if config.countingMode == .automatic {
                    isAutomaticCountingActive = true
                    poseStatus = .tracking
                    poseRecognition.beginCounting(activeStartUptime: now)
                }
                speech.speakPriority("开始")
                events.append(WorkoutEvent(offset: 0, kind: .announcement("开始")))
                startClock()
            } catch is CancellationError {
                return
            } catch {
                fail(error)
            }
        }
    }

    func incrementCount() {
        guard phase == .active, config.counterEnabled else { return }
        applyCount(at: currentOffset, provideHaptic: true)
    }

    private func applyCount(at offset: TimeInterval, provideHaptic: Bool) {
        // A manual correction can arrive while Vision is finishing an older
        // frame. Keep count events monotonic so the exported overlay never
        // shows a future total before that correction happened.
        let safeOffset = max(max(0, offset), lastCountEventOffset)
        lastCountEventOffset = safeOffset
        count += 1
        events.append(WorkoutEvent(offset: safeOffset, kind: .countChanged(count)))
        if provideHaptic {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        if config.countAnnouncementEnabled,
           count.isMultiple(of: config.countAnnouncementInterval) {
            let text = "\(count)次"
            if speech.speakCount(text) {
                events.append(WorkoutEvent(offset: safeOffset, kind: .announcement(text)))
            }
        }
    }

    func undoCount() {
        guard phase == .active, config.counterEnabled, count > 0 else { return }
        count -= 1
        let offset = max(currentOffset, lastCountEventOffset)
        lastCountEventOffset = offset
        events.append(WorkoutEvent(offset: offset, kind: .countChanged(count)))
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func finishManually() {
        guard phase == .active else { return }
        Task { await finalize(reason: .manual) }
    }

    func switchCamera() {
        guard phase == .framing, config.recordingEnabled else { return }
        Task {
            do {
                try await cameraRecorder.switchCamera()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateCameraOrientation(_ orientation: UIDeviceOrientation) {
        guard phase == .preparingCamera || phase == .framing else { return }
        cameraRecorder.updateOrientation(orientation)
    }

    func useManualCountingForCurrentSession() {
        guard phase == .framing, config.countingMode == .automatic else { return }
        config.countingMode = .manual
        isAutomaticCountingActive = false
        poseStatus = .inactive
        poseRecognition.pause()
    }

    func saveResult() {
        guard let url = result?.videoURL, !isSaved else { return }
        Task {
            do {
                try await PhotoLibrarySaver.saveVideo(at: url)
                isSaved = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func retry() {
        cleanupTemporaryFiles(keepOutput: false)
        prepare(config: config)
    }

    func returnHome() {
        poseRecognition.stop()
        cleanupTemporaryFiles(keepOutput: false)
        resetSessionState()
        phase = .idle
    }

    func cancelBeforeStart() {
        cameraRecorder.stopSession()
        poseRecognition.stop()
        cleanupTemporaryFiles(keepOutput: false)
        resetSessionState()
        phase = .idle
    }

    private var currentOffset: TimeInterval {
        guard let activeStartUptime else { return 0 }
        return max(0, ProcessInfo.processInfo.systemUptime - activeStartUptime)
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, phase == .active {
                let elapsed = currentOffset
                elapsedSeconds = Int(floor(elapsed))

                if config.timerEnabled {
                    let remaining = max(0, Int(ceil(TimeInterval(config.durationSeconds) - elapsed)))
                    remainingSeconds = remaining
                    announceTimeIfNeeded(remaining)

                    if elapsed >= TimeInterval(config.durationSeconds), config.autoStopAtTimerEnd {
                        await finalize(reason: .timerFinished)
                        return
                    }
                }

                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func announceTimeIfNeeded(_ remaining: Int) {
        guard config.shouldAnnounce(remainingSeconds: remaining),
              !announcedSeconds.contains(remaining) else { return }
        announcedSeconds.insert(remaining)
        let text = "还剩\(remaining)秒"
        speech.speakPriority(text)
        events.append(WorkoutEvent(offset: currentOffset, kind: .announcement(text)))
    }

    private func finalize(reason: WorkoutEndReason) async {
        guard !isFinalizing, phase == .active else { return }
        isFinalizing = true
        phase = .processing
        isAutomaticCountingActive = false
        poseRecognition.pause()
        speech.stop()

        let actualDuration = max(0.1, currentOffset)
        elapsedSeconds = Int(floor(actualDuration))
        if config.timerEnabled {
            remainingSeconds = max(0, config.durationSeconds - elapsedSeconds)
        }

        do {
            var videoURL: URL?
            if config.recordingEnabled {
                let finishedRawURL = try await cameraRecorder.stopRecording()
                rawURL = finishedRawURL
                let trimStart = max(0, (activeStartUptime ?? 0) - (rawStartUptime ?? 0))
                videoURL = try await VideoComposer.compose(
                    rawURL: finishedRawURL,
                    trimStart: trimStart,
                    actualDuration: actualDuration,
                    config: config,
                    events: events
                )
            }

            cameraRecorder.stopSession()
            result = WorkoutResult(
                duration: actualDuration,
                count: count,
                endReason: reason,
                videoURL: videoURL
            )
            phase = .result
            isFinalizing = false
        } catch {
            isFinalizing = false
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        cameraRecorder.stopSession()
        poseRecognition.stop()
        speech.stop()
        errorMessage = error.localizedDescription
        phase = .failed
    }

    private func resetSessionState() {
        clockTask?.cancel()
        clockTask = nil
        events = []
        count = 0
        elapsedSeconds = 0
        remainingSeconds = config.durationSeconds
        result = nil
        isSaved = false
        errorMessage = nil
        poseStatus = .inactive
        isAutomaticCountingActive = false
        activeStartUptime = nil
        rawStartUptime = nil
        announcedSeconds = []
        lastCountEventOffset = 0
        isFinalizing = false
        recognitionSessionID = UUID()
    }

    private var recognitionSessionID = UUID()

    private func handlePoseStatus(_ status: PoseTrackingStatus) {
        guard config.countingMode == .automatic else { return }
        poseStatus = status
        if status == .performanceFallback {
            isAutomaticCountingActive = false
        }
    }

    private func handleAutomaticDetection(_ detection: RepDetection) {
        guard phase == .active,
              config.counterEnabled,
              config.countingMode == .automatic,
              isAutomaticCountingActive,
              detection.exercise == config.exerciseType,
              let activeStartUptime else { return }
        applyCount(at: detection.captureUptime - activeStartUptime, provideHaptic: false)
    }

    private func cleanupTemporaryFiles(keepOutput: Bool) {
        let fileManager = FileManager.default
        if let rawURL {
            try? fileManager.removeItem(at: rawURL)
        }
        if !keepOutput, let outputURL = result?.videoURL {
            try? fileManager.removeItem(at: outputURL)
        }
        rawURL = nil
    }
}
