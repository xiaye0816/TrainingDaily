import Combine
import Foundation
import UIKit

enum WorkoutPhase: Equatable {
    case idle
    case preparingCamera
    case framing
    case countdown(Int)
    case active
    case finishing
    case processing
    case result
    case failed
}

enum WorkoutScreenAwakePolicy {
    static func preventsAutoLock(phase: WorkoutPhase, isVideoProcessing: Bool) -> Bool {
        switch phase {
        case .preparingCamera, .framing, .countdown, .active, .finishing, .processing:
            true
        case .result:
            isVideoProcessing
        case .idle, .failed:
            false
        }
    }
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
    @Published private(set) var zoomOptions: [CameraZoomOption] = []
    @Published private(set) var selectedZoomFactor: CGFloat = 1
    @Published private(set) var isVideoProcessing = false
    @Published private(set) var currentRecordID: UUID?

    let cameraRecorder = CameraRecorder()
    let photoSave = PhotoSaveCoordinator()

    private let speech = SpeechCoordinator()
    private let poseRecognition = PoseRecognitionEngine()
    private var config = WorkoutConfig.default
    private var events: [WorkoutEvent] = []
    private var clockTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var activeStartUptime: TimeInterval?
    private var rawURL: URL?
    private var announcedSeconds: Set<Int> = []
    private var lastCountEventOffset: TimeInterval = 0
    private var isFinalizing = false
    private var workoutStartedAt = Date()
    private var photoSaveObservation: AnyCancellable?
    private var diagnosticsRecorder: WorkoutDiagnosticsRecorder?

    init() {
        WorkoutDiagnosticsRecorder.cleanup()
        photoSaveObservation = photoSave.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        speech.clipStartedHandler = { [weak self] clip, uptime, volume in
            self?.diagnosticsRecorder?.recordEvent(
                "speech_started",
                detail: "text=\(clip.text),volume=\(volume)",
                uptime: uptime
            )
            self?.cameraRecorder.scheduleSpeechClip(clip, atUptime: uptime, volume: volume)
        }
        speech.clipRequestedHandler = { [weak self] text, uptime in
            self?.diagnosticsRecorder?.recordEvent("speech_requested", detail: "text=\(text)", uptime: uptime)
        }
    }

    var displayTime: String {
        if config.timerEnabled {
            return remainingSeconds.clockText
        }
        return elapsedSeconds.clockText
    }

    var currentConfig: WorkoutConfig { config }

    var preventsAutoLock: Bool {
        WorkoutScreenAwakePolicy.preventsAutoLock(
            phase: phase,
            isVideoProcessing: isVideoProcessing
        )
    }

    var canBeginCountdown: Bool {
        config.countingMode != .automatic || poseStatus.isReady
    }

    func prepare(config: WorkoutConfig) {
        resetSessionState()
        self.config = config.normalized
        if self.config.countingMode == .automatic, self.config.diagnosticsEnabled {
            diagnosticsRecorder = WorkoutDiagnosticsRecorder(config: self.config)
            diagnosticsRecorder?.recordEvent("session_preparing")
        }
        // Speech rendering must never hold the camera preparation screen or
        // pre-start AVAudioEngine while AVCaptureSession configures its audio
        // route. Warm the cache opportunistically and let playback start the
        // engine only when a prompt is actually needed.
        speech.preload(Self.announcementPrompts(for: self.config))
        workoutStartedAt = Date()
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
                diagnosticsRecorder: diagnosticsRecorder,
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
                        poseAnalyzer: analyzer,
                        diagnosticsRecorder: diagnosticsRecorder
                    )
                    await refreshZoomOptions()
                }
                phase = .framing
                cameraRecorder.updateOrientation(UIDevice.current.orientation)
                attemptAutomaticStartIfReady()
            } catch {
                fail(error)
            }
        }
    }

    func beginCountdown(orientation: UIDeviceOrientation) {
        guard phase == .framing, canBeginCountdown, countdownTask == nil else { return }
        // Change phase synchronously so consecutive Vision callbacks cannot
        // enqueue more than one countdown before the task begins executing.
        phase = .countdown(3)
        diagnosticsRecorder?.recordEvent("countdown_started")

        countdownTask = Task { [weak self] in
            guard let self else { return }
            do {
                if config.countingMode == .automatic {
                    poseRecognition.pause()
                }
                for number in stride(from: 3, through: 1, by: -1) {
                    phase = .countdown(number)
                    speech.speakPriority("\(number)")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }

                var now = ProcessInfo.processInfo.systemUptime
                if config.recordingEnabled {
                    remainingSeconds = config.durationSeconds
                    elapsedSeconds = 0
                    updateRecordingOverlay()
                    let start = try await cameraRecorder.startRecording(orientation: orientation)
                    rawURL = start.url
                    now = start.uptime
                }
                activeStartUptime = now
                workoutStartedAt = Date()
                elapsedSeconds = 0
                remainingSeconds = config.durationSeconds
                phase = .active
                diagnosticsRecorder?.recordEvent("workout_started", uptime: now)
                updateRecordingOverlay()
                if config.countingMode == .automatic {
                    isAutomaticCountingActive = true
                    poseStatus = .tracking
                    poseRecognition.beginCounting(activeStartUptime: now)
                }
                speech.speakPriority("开始")
                events.append(WorkoutEvent(offset: 0, kind: .announcement("开始")))
                startClock()
                countdownTask = nil
            } catch is CancellationError {
                countdownTask = nil
                return
            } catch {
                countdownTask = nil
                fail(error)
            }
        }
    }

    func incrementCount() {
        guard phase == .active || phase == .finishing, config.counterEnabled else { return }
        applyCount(at: currentOffset, provideHaptic: true)
    }

    private func applyCount(at offset: TimeInterval, provideHaptic: Bool) {
        // A manual correction can arrive while Vision is finishing an older
        // frame. Keep count events monotonic so the exported overlay never
        // shows a future total before that correction happened.
        let safeOffset = max(max(0, offset), lastCountEventOffset)
        lastCountEventOffset = safeOffset
        count += 1
        diagnosticsRecorder?.recordEvent("count_applied", detail: "count=\(count),offset=\(safeOffset)")
        events.append(WorkoutEvent(offset: safeOffset, kind: .countChanged(count)))
        updateRecordingOverlay()
        if provideHaptic {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        if phase == .active,
           config.countAnnouncementEnabled,
           count.isMultiple(of: config.countAnnouncementInterval) {
            let text = "\(count)"
            if speech.speakCount(text) {
                events.append(WorkoutEvent(offset: safeOffset, kind: .announcement(text)))
            }
        }
    }

    func undoCount() {
        guard phase == .active || phase == .finishing, config.counterEnabled, count > 0 else { return }
        count -= 1
        let offset = max(currentOffset, lastCountEventOffset)
        diagnosticsRecorder?.recordEvent("count_undone", detail: "count=\(count),offset=\(offset)")
        lastCountEventOffset = offset
        events.append(WorkoutEvent(offset: offset, kind: .countChanged(count)))
        updateRecordingOverlay()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func finishManually() {
        guard phase == .active else { return }
        Task { await finalize(reason: .manual) }
    }

    func handleCaptureInterruption() {
        guard phase == .active || phase == .finishing else { return }
        Task { await finalize(reason: .interrupted) }
    }

    func switchCamera() {
        guard phase == .framing, config.recordingEnabled else { return }
        Task {
            do {
                try await cameraRecorder.switchCamera()
                diagnosticsRecorder?.recordEvent("camera_switched")
                await refreshZoomOptions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectZoom(_ option: CameraZoomOption) {
        guard phase == .framing else { return }
        selectedZoomFactor = option.deviceFactor
        diagnosticsRecorder?.recordEvent("zoom_selected", detail: "factor=\(option.deviceFactor)")
        Task { await cameraRecorder.setZoomFactor(option.deviceFactor) }
        if config.countingMode == .automatic {
            poseRecognition.resetForCameraChange()
        }
    }

    func setPinchZoom(_ factor: CGFloat) {
        guard phase == .framing else { return }
        let bounds = zoomOptions.map(\.deviceFactor)
        guard let minimum = bounds.min(), let maximum = bounds.max() else { return }
        let resolved = min(max(factor, minimum), maximum)
        selectedZoomFactor = resolved
        Task { await cameraRecorder.setZoomFactor(resolved) }
    }

    private func refreshZoomOptions() async {
        zoomOptions = await cameraRecorder.availableZoomOptions()
        if let oneTimes = zoomOptions.first(where: { $0.label == "1×" }) ?? zoomOptions.first {
            selectedZoomFactor = oneTimes.deviceFactor
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
        guard let url = result?.videoURL else { return }
        errorMessage = nil
        photoSave.save(videoURL: url) { [weak self] in
            guard let self else { return }
            isSaved = true
            if let currentRecordID {
                WorkoutHistoryStore.shared.markSavedToPhotos(currentRecordID)
            }
        }
    }

    func retry() {
        guard !isVideoProcessing else { return }
        cleanupTemporaryFiles(keepOutput: false)
        prepare(config: config)
    }

    func returnHome() {
        guard !isVideoProcessing else { return }
        poseRecognition.stop()
        cleanupTemporaryFiles(keepOutput: false)
        resetSessionState()
        phase = .idle
    }

    func cancelBeforeStart() {
        cameraRecorder.stopSession()
        poseRecognition.stop()
        diagnosticsRecorder?.finish(state: "cancelled")
        cleanupTemporaryFiles(keepOutput: false)
        resetSessionState()
        phase = .idle
    }

    private var currentOffset: TimeInterval {
        guard let activeStartUptime else { return 0 }
        return max(0, ProcessInfo.processInfo.systemUptime - activeStartUptime)
    }

    private static func announcementPrompts(for config: WorkoutConfig) -> [String] {
        var prompts = ["3", "2", "1", "开始", "停"]
        if config.timeAnnouncementEnabled {
            let upcoming = (1..<config.durationSeconds).reversed().filter {
                config.shouldAnnounce(remainingSeconds: $0)
            }.prefix(24)
            prompts.append(contentsOf: upcoming.map {
                WorkoutTimingPolicy.announcementText(
                    remainingSeconds: $0,
                    finalCountdownEnabled: config.finalCountdownEnabled
                )
            })
        }
        if config.countAnnouncementEnabled {
            prompts.append(contentsOf: (1...20).map { "\($0 * config.countAnnouncementInterval)" })
        }
        return prompts
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, phase == .active {
                let elapsed = currentOffset
                elapsedSeconds = Int(floor(elapsed))
                if !config.timerEnabled { updateRecordingOverlay() }

                if config.timerEnabled {
                    let remaining = max(0, Int(ceil(TimeInterval(config.durationSeconds) - elapsed)))
                    remainingSeconds = remaining
                    updateRecordingOverlay()
                    announceTimeIfNeeded(remaining)

                    if elapsed >= TimeInterval(config.durationSeconds), config.autoStopAtTimerEnd {
                        await beginTimerFinish()
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
        let text = WorkoutTimingPolicy.announcementText(
            remainingSeconds: remaining,
            finalCountdownEnabled: config.finalCountdownEnabled
        )
        speech.speakPriority(text)
        events.append(WorkoutEvent(offset: currentOffset, kind: .announcement(text)))
    }

    private func beginTimerFinish() async {
        guard phase == .active else { return }
        phase = .finishing
        remainingSeconds = 0
        updateRecordingOverlay()
        speech.stop()
        if config.stopAnnouncementEnabled {
            events.append(WorkoutEvent(offset: currentOffset, kind: .announcement("停")))
            _ = await speech.speakPriorityAndWait("停")
        }
        try? await Task.sleep(
            nanoseconds: UInt64(WorkoutTimingPolicy.finishTailDuration * 1_000_000_000)
        )
        await finalize(reason: .timerFinished)
    }

    private func finalize(reason: WorkoutEndReason) async {
        guard !isFinalizing, phase == .active || phase == .finishing else { return }
        isFinalizing = true
        isAutomaticCountingActive = false
        speech.stop()

        let recordedDuration = max(0.1, currentOffset)
        let resultDuration = reason == .timerFinished
            ? TimeInterval(config.durationSeconds)
            : recordedDuration
        elapsedSeconds = Int(floor(resultDuration))
        if config.timerEnabled {
            remainingSeconds = max(0, config.durationSeconds - elapsedSeconds)
        }

        let finalCount = count
        let finalizationSessionID = recognitionSessionID
        diagnosticsRecorder?.recordEvent("finalization_started", detail: "reason=\(reason.rawValue),count=\(finalCount)")

        if config.recordingEnabled {
            let pending = WorkoutHistoryStore.shared.beginRealtimeVideoFinalization(
                startedAt: workoutStartedAt,
                duration: resultDuration,
                count: finalCount,
                reason: reason,
                config: config
            )
            currentRecordID = pending.id
            isVideoProcessing = true
            result = WorkoutResult(
                duration: resultDuration,
                count: finalCount,
                endReason: reason,
                videoURL: nil,
                previewImageData: nil
            )
            phase = .result
            Task { [weak self] in
                await self?.completeVideoFinalization(
                    recordID: pending.id,
                    sessionID: finalizationSessionID
                )
            }
        } else {
            let historyRecord = WorkoutHistoryStore.shared.addWithoutVideo(
                startedAt: workoutStartedAt,
                duration: resultDuration,
                count: finalCount,
                reason: reason,
                config: config
            )
            currentRecordID = historyRecord.id
            diagnosticsRecorder?.finish(state: "completed")
            diagnosticsRecorder = nil
            result = WorkoutResult(
                duration: resultDuration,
                count: finalCount,
                endReason: reason,
                videoURL: nil,
                previewImageData: nil
            )
            isVideoProcessing = false
            isFinalizing = false
            phase = .result
        }
    }

    private func completeVideoFinalization(recordID: UUID, sessionID: UUID) async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinishWorkoutVideo")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        do {
            await poseRecognition.pauseAndDrain()
            await cameraRecorder.stopSessionAndWait()
            let finished = try await cameraRecorder.stopRecording()
            rawURL = finished.url
            let historyRecord = try WorkoutHistoryStore.shared.completeRealtimeVideo(recordID, videoURL: finished.url)
            rawURL = nil
            guard recognitionSessionID == sessionID else { return }
            let videoURL = WorkoutHistoryStore.shared.videoURL(for: historyRecord)
            if let videoURL {
                await diagnosticsRecorder?.attachVideo(from: videoURL)
            }
            diagnosticsRecorder?.finish(state: "completed")
            diagnosticsRecorder = nil
            let current = result
            result = WorkoutResult(
                duration: current?.duration ?? historyRecord.duration,
                count: current?.count ?? historyRecord.count,
                endReason: current?.endReason ?? historyRecord.endReason,
                videoURL: videoURL,
                previewImageData: finished.previewImageData
            )
            isVideoProcessing = false
            isFinalizing = false
        } catch {
            WorkoutHistoryStore.shared.failRealtimeVideo(recordID, message: error.localizedDescription)
            diagnosticsRecorder?.recordEvent("finalization_failed", detail: error.localizedDescription)
            diagnosticsRecorder?.finish(state: "failed", error: error.localizedDescription)
            diagnosticsRecorder = nil
            guard recognitionSessionID == sessionID else { return }
            cameraRecorder.stopSession()
            rawURL = nil
            isFinalizing = false
            isVideoProcessing = false
            errorMessage = "录像写入失败，成绩已保留：\(error.localizedDescription)"
        }
    }

    private func fail(_ error: Error) {
        cameraRecorder.stopSession()
        poseRecognition.stop()
        speech.stop()
        diagnosticsRecorder?.recordEvent("session_failed", detail: error.localizedDescription)
        diagnosticsRecorder?.finish(state: "failed", error: error.localizedDescription)
        diagnosticsRecorder = nil
        errorMessage = error.localizedDescription
        phase = .failed
    }

    private func resetSessionState() {
        clockTask?.cancel()
        clockTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        speech.stop()
        events = []
        count = 0
        elapsedSeconds = 0
        remainingSeconds = config.durationSeconds
        result = nil
        isSaved = false
        photoSave.dismiss()
        errorMessage = nil
        poseStatus = .inactive
        isAutomaticCountingActive = false
        zoomOptions = []
        selectedZoomFactor = 1
        isVideoProcessing = false
        currentRecordID = nil
        activeStartUptime = nil
        announcedSeconds = []
        lastCountEventOffset = 0
        isFinalizing = false
        diagnosticsRecorder = nil
        recognitionSessionID = UUID()
    }

    private var recognitionSessionID = UUID()

    private func handlePoseStatus(_ status: PoseTrackingStatus) {
        guard config.countingMode == .automatic else { return }
        poseStatus = status
        attemptAutomaticStartIfReady()
        if status == .performanceFallback {
            isAutomaticCountingActive = false
        }
    }

    private func attemptAutomaticStartIfReady() {
        guard phase == .framing,
              config.countingMode == .automatic,
              config.autoStartWhenPersonReady,
              poseStatus.isReady else { return }
        beginCountdown(orientation: UIDevice.current.orientation)
    }

    private func handleAutomaticDetection(_ detection: RepDetection) {
        guard phase == .active || phase == .finishing,
              config.counterEnabled,
              config.countingMode == .automatic,
              isAutomaticCountingActive,
              detection.exercise == config.exerciseType,
              let activeStartUptime else { return }
        applyCount(at: detection.captureUptime - activeStartUptime, provideHaptic: false)
    }

    private func updateRecordingOverlay() {
        guard config.recordingEnabled else { return }
        cameraRecorder.updateRecordingOverlay(
            RecordingOverlaySnapshot(
                timeText: config.timerEnabled ? remainingSeconds.clockText : elapsedSeconds.clockText,
                count: config.counterEnabled ? count : nil
            )
        )
    }

    private func cleanupTemporaryFiles(keepOutput: Bool) {
        let fileManager = FileManager.default
        if let rawURL {
            try? fileManager.removeItem(at: rawURL)
        }
        if !keepOutput, currentRecordID == nil, let outputURL = result?.videoURL {
            try? fileManager.removeItem(at: outputURL)
        }
        rawURL = nil
    }
}
