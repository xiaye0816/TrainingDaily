@preconcurrency import AVFoundation
import Foundation
import Vision

enum BodyJoint: String, CaseIterable, Sendable {
    case nose
    case neck
    case root
    case leftShoulder
    case rightShoulder
    case leftWrist
    case rightWrist
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle
}

struct PosePoint: Equatable, Sendable {
    let x: Double
    let y: Double
    let confidence: Double

    func distance(to other: PosePoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

struct PoseBounds: Equatable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var area: Double { width * height }
    var centerX: Double { (minX + maxX) / 2 }
    var centerY: Double { (minY + maxY) / 2 }

    func padded(by amount: Double) -> CGRect {
        CGRect(
            x: max(0, minX - amount),
            y: max(0, minY - amount),
            width: min(1, maxX + amount) - max(0, minX - amount),
            height: min(1, maxY + amount) - max(0, minY - amount)
        )
    }
}

struct BodyPoseSample: Equatable, Sendable {
    let captureUptime: TimeInterval
    let points: [BodyJoint: PosePoint]
    let personCount: Int

    func point(_ joint: BodyJoint, minimumConfidence: Double = 0.25) -> PosePoint? {
        guard let point = points[joint], point.confidence >= minimumConfidence else { return nil }
        return point
    }

    var bounds: PoseBounds? {
        let visible = points.values.filter { $0.confidence >= 0.25 }
        guard let first = visible.first else { return nil }
        return visible.dropFirst().reduce(
            PoseBounds(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        ) { bounds, point in
            PoseBounds(
                minX: min(bounds.minX, point.x),
                minY: min(bounds.minY, point.y),
                maxX: max(bounds.maxX, point.x),
                maxY: max(bounds.maxY, point.y)
            )
        }
    }
}

enum PoseTrackingStatus: Equatable, Sendable {
    case inactive
    case findingPerson
    case multiplePeople
    case showFullBody
    case showHead
    case showFeet
    case moveCloser
    case moveFarther
    case turnSideways
    case faceCamera
    case holdPosition
    case ready
    case tracking
    case lost
    case performanceFallback

    var message: String {
        switch self {
        case .inactive: "自动识别未启用"
        case .findingPerson: "请进入取景框"
        case .multiplePeople: "画面中请只保留一名训练者"
        case .showFullBody: "请确保全身和四肢完整入镜"
        case .showHead: "请露出头顶，并在上方留一点空间"
        case .showFeet: "请露出双脚，并在脚下留一点空间"
        case .moveCloser: "请靠近一些"
        case .moveFarther: "请离手机远一些"
        case .turnSideways: "请将身体侧面对准手机"
        case .faceCamera: "请正面对准手机"
        case .holdPosition: "位置合适，请保持"
        case .ready: "取景合格，可以开始"
        case .tracking: "自动识别中"
        case .lost: "人物离开画面，计次已暂停"
        case .performanceFallback: "识别速度不足，已切换手动计次"
        }
    }

    var isReady: Bool { self == .ready }
}

struct RepDetection: Equatable, Sendable {
    let captureUptime: TimeInterval
    let exercise: ExerciseType
    let confidence: Double
}

enum PoseQualityEvaluator {
    static func adjustment(for sample: BodyPoseSample, exercise: ExerciseType) -> PoseTrackingStatus? {
        if sample.personCount > 1 { return .multiplePeople }
        guard let bounds = sample.bounds else { return .findingPerson }

        switch exercise {
        case .sitUp:
            guard bestSide(in: sample) != nil else { return .showFullBody }
            if bounds.minX < 0.015 || bounds.minY < 0.015 || bounds.maxX > 0.985 || bounds.maxY > 0.985 {
                return .moveFarther
            }
            if max(bounds.width, bounds.height) < 0.30 { return .moveCloser }
            if max(bounds.width, bounds.height) > 0.97 { return .moveFarther }
            if appearsFrontFacing(sample) { return .turnSideways }
        case .jumpRope:
            if sample.point(.nose) == nil { return .showHead }
            if sample.point(.leftAnkle) == nil || sample.point(.rightAnkle) == nil { return .showFeet }
            let required: [BodyJoint] = [
                .nose, .leftShoulder, .rightShoulder,
                .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle
            ]
            guard required.allSatisfy({ sample.point($0) != nil }) else { return .showFullBody }
            guard let nose = sample.point(.nose),
                  let leftAnkle = sample.point(.leftAnkle),
                  let rightAnkle = sample.point(.rightAnkle) else { return .showFullBody }
            if nose.y > 0.975 { return .showHead }
            if min(leftAnkle.y, rightAnkle.y) < 0.025 { return .showFeet }
            if bounds.height < 0.38 { return .moveCloser }
            if bounds.height > 0.97 { return .moveFarther }
            if !appearsFrontFacing(sample) { return .faceCamera }
        }
        return nil
    }

    static func bestSide(
        in sample: BodyPoseSample
    ) -> (shoulder: PosePoint, hip: PosePoint, knee: PosePoint, ankle: PosePoint)? {
        let left = side(in: sample, shoulder: .leftShoulder, hip: .leftHip, knee: .leftKnee, ankle: .leftAnkle)
        let right = side(in: sample, shoulder: .rightShoulder, hip: .rightHip, knee: .rightKnee, ankle: .rightAnkle)
        switch (left, right) {
        case let (.some(left), .some(right)):
            let leftConfidence = left.shoulder.confidence + left.hip.confidence + left.knee.confidence + left.ankle.confidence
            let rightConfidence = right.shoulder.confidence + right.hip.confidence + right.knee.confidence + right.ankle.confidence
            return leftConfidence >= rightConfidence ? left : right
        case let (.some(left), .none): return left
        case let (.none, .some(right)): return right
        case (.none, .none): return nil
        }
    }

    private static func side(
        in sample: BodyPoseSample,
        shoulder: BodyJoint,
        hip: BodyJoint,
        knee: BodyJoint,
        ankle: BodyJoint
    ) -> (shoulder: PosePoint, hip: PosePoint, knee: PosePoint, ankle: PosePoint)? {
        guard let shoulderPoint = sample.point(shoulder),
              let hipPoint = sample.point(hip),
              let kneePoint = sample.point(knee),
              let anklePoint = sample.point(ankle) else { return nil }
        return (shoulderPoint, hipPoint, kneePoint, anklePoint)
    }

    private static func appearsFrontFacing(_ sample: BodyPoseSample) -> Bool {
        guard let leftShoulder = sample.point(.leftShoulder),
              let rightShoulder = sample.point(.rightShoulder),
              let leftHip = sample.point(.leftHip),
              let rightHip = sample.point(.rightHip),
              let bounds = sample.bounds else { return false }
        let lateralSpread = (abs(leftShoulder.x - rightShoulder.x) + abs(leftHip.x - rightHip.x)) / 2
        return lateralSpread / max(bounds.height, 0.1) >= 0.12
    }
}

struct SitUpRepCounter {
    struct Thresholds {
        var downMaximumTorsoAngle = 32.0
        var downMaximumShoulderHeight = 0.18
        var upMinimumTorsoAngle = 52.0
        var upMaximumShoulderKneeDistance = 0.76
        var stableSampleCount = 2
        var minimumRepInterval = 0.45
    }

    private enum Phase {
        case seekingDown
        case readyForUp
        case waitingForDown
    }

    private var phase = Phase.seekingDown
    private var stableSamples = 0
    private var lastRepUptime = -Double.infinity
    private let thresholds: Thresholds

    init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    mutating func process(_ sample: BodyPoseSample) -> RepDetection? {
        guard let side = PoseQualityEvaluator.bestSide(in: sample) else {
            return nil
        }
        let bodyScale = max(side.shoulder.distance(to: side.ankle), 0.08)
        let rawAngle = abs(atan2(side.shoulder.y - side.hip.y, side.shoulder.x - side.hip.x))
        let torsoAngle = min(rawAngle, abs(.pi - rawAngle)) * 180 / .pi
        let shoulderKneeDistance = side.shoulder.distance(to: side.knee) / bodyScale
        let shoulderHeight = (side.shoulder.y - side.hip.y) / bodyScale
        let isDown = torsoAngle <= thresholds.downMaximumTorsoAngle
            && shoulderHeight <= thresholds.downMaximumShoulderHeight
        let isUp = torsoAngle >= thresholds.upMinimumTorsoAngle
            && shoulderKneeDistance <= thresholds.upMaximumShoulderKneeDistance

        switch phase {
        case .seekingDown, .waitingForDown:
            stableSamples = isDown ? stableSamples + 1 : 0
            if stableSamples >= thresholds.stableSampleCount {
                phase = .readyForUp
                stableSamples = 0
            }
        case .readyForUp:
            stableSamples = isUp ? stableSamples + 1 : 0
            guard stableSamples >= thresholds.stableSampleCount,
                  sample.captureUptime - lastRepUptime >= thresholds.minimumRepInterval else { return nil }
            phase = .waitingForDown
            stableSamples = 0
            lastRepUptime = sample.captureUptime
            let confidence = [side.shoulder, side.hip, side.knee, side.ankle]
                .map(\.confidence)
                .reduce(0, +) / 4
            return RepDetection(captureUptime: sample.captureUptime, exercise: .sitUp, confidence: confidence)
        }
        return nil
    }

    mutating func resetCycle() {
        phase = .seekingDown
        stableSamples = 0
    }
}

struct JumpRopeRepCounter {
    struct Thresholds {
        var takeoffDisplacement = 0.018
        var takeoffVelocity = 0.08
        var maximumAnkleDifference = 0.09
        var landingDisplacement = 0.012
        var landingMaximumVelocity = 0.05
        var minimumPeakDisplacement = 0.025
        var minimumFlightDuration = 0.10
        var maximumFlightDuration = 0.65
        var cycleTimeout = 0.8
        var minimumRepInterval = 0.18
    }

    private enum Phase {
        case grounded
        case airborne(start: TimeInterval, peak: Double, wristTravel: Double)
    }

    private var phase = Phase.grounded
    private var baseline: Double?
    private var smoothedHeight: Double?
    private var previousHeight: Double?
    private var previousWristMidpoint: PosePoint?
    private var previousUptime: TimeInterval?
    private var lastRepUptime = -Double.infinity
    private let thresholds: Thresholds

    init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    mutating func process(_ sample: BodyPoseSample) -> RepDetection? {
        guard let leftShoulder = sample.point(.leftShoulder),
              let rightShoulder = sample.point(.rightShoulder),
              let leftHip = sample.point(.leftHip),
              let rightHip = sample.point(.rightHip),
              let leftAnkle = sample.point(.leftAnkle),
              let rightAnkle = sample.point(.rightAnkle) else { return nil }

        let shoulderMidpoint = midpoint(leftShoulder, rightShoulder)
        let hipMidpoint = midpoint(leftHip, rightHip)
        let ankleMidpoint = midpoint(leftAnkle, rightAnkle)
        let wristMidpoint: PosePoint? = {
            guard let leftWrist = sample.point(.leftWrist),
                  let rightWrist = sample.point(.rightWrist) else { return nil }
            return midpoint(leftWrist, rightWrist)
        }()
        let bodyScale = max(shoulderMidpoint.distance(to: ankleMidpoint), 0.15)
        let rawHeight = ankleMidpoint.y * 0.65 + hipMidpoint.y * 0.35
        let filteredHeight = smoothedHeight.map { $0 * 0.55 + rawHeight * 0.45 } ?? rawHeight
        let deltaTime = max(0.001, sample.captureUptime - (previousUptime ?? sample.captureUptime - 1.0 / 15.0))
        let velocity = (filteredHeight - (previousHeight ?? filteredHeight)) / bodyScale / deltaTime
        let ground = baseline ?? filteredHeight
        let displacement = (filteredHeight - ground) / bodyScale
        let ankleDifference = abs(leftAnkle.y - rightAnkle.y) / bodyScale
        let wristDelta = wristMidpoint.flatMap { current in
            previousWristMidpoint.map { current.distance(to: $0) / bodyScale }
        } ?? 0

        smoothedHeight = filteredHeight
        previousHeight = filteredHeight
        previousWristMidpoint = wristMidpoint
        previousUptime = sample.captureUptime

        if baseline == nil {
            baseline = filteredHeight
            return nil
        }

        switch phase {
        case .grounded:
            if displacement < thresholds.takeoffDisplacement {
                baseline = ground * 0.94 + filteredHeight * 0.06
            }
            if displacement >= thresholds.takeoffDisplacement,
               velocity > thresholds.takeoffVelocity,
               ankleDifference < thresholds.maximumAnkleDifference {
                phase = .airborne(start: sample.captureUptime, peak: displacement, wristTravel: wristDelta)
            }
        case let .airborne(start, peak, wristTravel):
            let nextPeak = max(peak, displacement)
            let nextWristTravel = wristTravel + wristDelta
            let flightDuration = sample.captureUptime - start
            if flightDuration > thresholds.cycleTimeout {
                phase = .grounded
                baseline = filteredHeight
            } else if displacement <= thresholds.landingDisplacement,
                      velocity <= thresholds.landingMaximumVelocity {
                phase = .grounded
                baseline = filteredHeight
                guard nextPeak >= thresholds.minimumPeakDisplacement,
                      flightDuration >= thresholds.minimumFlightDuration,
                      flightDuration <= thresholds.maximumFlightDuration,
                      sample.captureUptime - lastRepUptime >= thresholds.minimumRepInterval else { return nil }
                lastRepUptime = sample.captureUptime
                let jointConfidence = [leftHip, rightHip, leftAnkle, rightAnkle]
                    .map(\.confidence)
                    .reduce(0, +) / 4
                let motionConfidence = min(1, 0.72 + nextWristTravel * 1.8)
                return RepDetection(
                    captureUptime: sample.captureUptime,
                    exercise: .jumpRope,
                    confidence: min(jointConfidence, motionConfidence)
                )
            } else {
                phase = .airborne(start: start, peak: nextPeak, wristTravel: nextWristTravel)
            }
        }
        return nil
    }

    mutating func resetCycle() {
        phase = .grounded
        baseline = nil
        smoothedHeight = nil
        previousHeight = nil
        previousWristMidpoint = nil
        previousUptime = nil
    }

    private func midpoint(_ first: PosePoint, _ second: PosePoint) -> PosePoint {
        PosePoint(
            x: (first.x + second.x) / 2,
            y: (first.y + second.y) / 2,
            confidence: min(first.confidence, second.confidence)
        )
    }
}

private enum ExerciseCounter {
    case sitUp(SitUpRepCounter)
    case jumpRope(JumpRopeRepCounter)

    init(exercise: ExerciseType) {
        switch exercise {
        case .sitUp: self = .sitUp(SitUpRepCounter())
        case .jumpRope: self = .jumpRope(JumpRopeRepCounter())
        }
    }

    mutating func process(_ sample: BodyPoseSample) -> RepDetection? {
        switch self {
        case var .sitUp(counter):
            let detection = counter.process(sample)
            self = .sitUp(counter)
            return detection
        case var .jumpRope(counter):
            let detection = counter.process(sample)
            self = .jumpRope(counter)
            return detection
        }
    }

    mutating func resetCycle() {
        switch self {
        case var .sitUp(counter):
            counter.resetCycle()
            self = .sitUp(counter)
        case var .jumpRope(counter):
            counter.resetCycle()
            self = .jumpRope(counter)
        }
    }
}

final class PoseRecognitionEngine: NSObject, @unchecked Sendable {
    typealias StatusHandler = @Sendable (PoseTrackingStatus) -> Void
    typealias DetectionHandler = @Sendable (RepDetection) -> Void

    let captureQueue = DispatchQueue(label: "com.tiantiandaka.pose-analysis", qos: .userInitiated)

    private enum Mode {
        case inactive
        case framing
        case counting(activeStartUptime: TimeInterval)
    }

    private let request = VNDetectHumanBodyPoseRequest()
    private var exercise = ExerciseType.sitUp
    private var counter = ExerciseCounter(exercise: .sitUp)
    private var mode = Mode.inactive
    private var statusHandler: StatusHandler?
    private var detectionHandler: DetectionHandler?
    private var lastStatus = PoseTrackingStatus.inactive
    private var framingSamples: [(time: TimeInterval, isValid: Bool)] = []
    private var lastAnalyzedUptime = -Double.infinity
    private var lastValidPoseUptime: TimeInterval?
    private var processedFrameTimes: [TimeInterval] = []
    private var didResetForCurrentLoss = false
    private let submissionLock = NSLock()
    private var hasPendingFrame = false

    func submit(_ sampleBuffer: CMSampleBuffer) {
        submissionLock.lock()
        guard !hasPendingFrame else {
            submissionLock.unlock()
            return
        }
        hasPendingFrame = true
        submissionLock.unlock()
        let reference = SendablePoseSampleBuffer(sampleBuffer)
        captureQueue.async { [weak self] in
            guard let self else { return }
            processFrame(reference.value)
            submissionLock.lock()
            hasPendingFrame = false
            submissionLock.unlock()
        }
    }

    func configure(
        exercise: ExerciseType,
        statusHandler: @escaping StatusHandler,
        detectionHandler: @escaping DetectionHandler
    ) {
        captureQueue.sync {
            self.exercise = exercise
            counter = ExerciseCounter(exercise: exercise)
            self.statusHandler = statusHandler
            self.detectionHandler = detectionHandler
            mode = .framing
            resetAnalysisState()
            emit(.findingPerson)
        }
    }

    func beginCounting(activeStartUptime: TimeInterval) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            counter = ExerciseCounter(exercise: exercise)
            mode = .counting(activeStartUptime: activeStartUptime)
            processedFrameTimes = []
            lastValidPoseUptime = nil
            didResetForCurrentLoss = false
            emit(.tracking)
        }
    }

    func pause() {
        captureQueue.async { [weak self] in
            self?.mode = .inactive
        }
    }

    func resetForCameraChange() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            mode = .framing
            counter = ExerciseCounter(exercise: exercise)
            resetAnalysisState()
            emit(.findingPerson)
        }
    }

    func stop() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            mode = .inactive
            statusHandler = nil
            detectionHandler = nil
            resetAnalysisState()
        }
    }

    private func resetAnalysisState() {
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        framingSamples = []
        lastAnalyzedUptime = -Double.infinity
        lastValidPoseUptime = nil
        processedFrameTimes = []
        didResetForCurrentLoss = false
    }

    private func emit(_ status: PoseTrackingStatus) {
        guard status != lastStatus else { return }
        lastStatus = status
        statusHandler?(status)
    }

    private func processFrame(_ sampleBuffer: CMSampleBuffer) {
        if case .inactive = mode { return }

        let captureUptime = Self.captureUptime(for: sampleBuffer)
        guard captureUptime - lastAnalyzedUptime >= 1.0 / 15.0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalyzedUptime = captureUptime

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            handleObservations(observations, captureUptime: captureUptime)
        } catch {
            handleMissingPose(at: captureUptime)
        }
    }

    private static func captureUptime(for sampleBuffer: CMSampleBuffer) -> TimeInterval {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let currentUptime = ProcessInfo.processInfo.systemUptime
        guard presentationTime.isValid else { return currentUptime }
        let seconds = CMTimeGetSeconds(presentationTime)
        // AVCaptureVideoDataOutput normally timestamps frames on the host-time
        // clock. Fall back to callback arrival time if a device supplies a
        // different timebase so count events still share the workout clock.
        guard seconds.isFinite, abs(seconds - currentUptime) < 10 else { return currentUptime }
        return seconds
    }

    private func handleObservations(_ observations: [VNHumanBodyPoseObservation], captureUptime: TimeInterval) {
        let samples = observations.compactMap { makeSample(from: $0, captureUptime: captureUptime, personCount: observations.count) }
        guard var selected = samples.max(by: { score($0) < score($1) }) else {
            handleMissingPose(at: captureUptime)
            return
        }
        let significantPeople = samples.filter { ($0.bounds?.area ?? 0) >= (selected.bounds?.area ?? 0) * 0.35 }.count
        selected = BodyPoseSample(captureUptime: selected.captureUptime, points: selected.points, personCount: significantPeople)
        let adjustment = PoseQualityEvaluator.adjustment(for: selected, exercise: exercise)

        switch mode {
        case .framing:
            request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
            recordFramingSample(isValid: adjustment == nil, at: captureUptime)
            if framingIsReady(at: captureUptime) {
                emit(.ready)
            } else if adjustment == nil {
                emit(.holdPosition)
            } else {
                emit(adjustment ?? .findingPerson)
            }
        case let .counting(activeStartUptime):
            recordProcessedFrame(at: captureUptime)
            guard case .counting = mode else { return }
            guard captureUptime >= activeStartUptime else { return }
            guard adjustment == nil else {
                handleMissingPose(at: captureUptime)
                return
            }
            lastValidPoseUptime = captureUptime
            didResetForCurrentLoss = false
            emit(.tracking)
            if let detection = counter.process(selected) {
                detectionHandler?(detection)
            }
        case .inactive:
            break
        }
    }

    private func handleMissingPose(at captureUptime: TimeInterval) {
        switch mode {
        case .framing:
            recordFramingSample(isValid: false, at: captureUptime)
            emit(framingIsReady(at: captureUptime) ? .ready : .findingPerson)
        case .counting:
            recordProcessedFrame(at: captureUptime)
            emit(.lost)
            if let lastValidPoseUptime, captureUptime - lastValidPoseUptime > 0.5, !didResetForCurrentLoss {
                counter.resetCycle()
                didResetForCurrentLoss = true
            }
            if let lastValidPoseUptime, captureUptime - lastValidPoseUptime > 1 {
                request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
        case .inactive:
            break
        }
    }

    private func recordFramingSample(isValid: Bool, at captureUptime: TimeInterval) {
        framingSamples.append((captureUptime, isValid))
        framingSamples.removeAll { captureUptime - $0.time > 1.2 }
    }

    private func framingIsReady(at captureUptime: TimeInterval) -> Bool {
        guard let first = framingSamples.first,
              captureUptime - first.time >= 0.8,
              framingSamples.count >= 8 else { return false }
        let validCount = framingSamples.reduce(0) { $0 + ($1.isValid ? 1 : 0) }
        return Double(validCount) / Double(framingSamples.count) >= 0.75
    }

    private func recordProcessedFrame(at captureUptime: TimeInterval) {
        processedFrameTimes.append(captureUptime)
        processedFrameTimes.removeAll { captureUptime - $0 > 2 }
        guard let first = processedFrameTimes.first,
              captureUptime - first >= 1.9 else { return }
        let effectiveFPS = Double(max(0, processedFrameTimes.count - 1)) / max(0.001, captureUptime - first)
        if effectiveFPS < 12 {
            mode = .inactive
            emit(.performanceFallback)
        }
    }

    private func score(_ sample: BodyPoseSample) -> Double {
        guard let bounds = sample.bounds else { return 0 }
        let distanceFromCenter = hypot(bounds.centerX - 0.5, bounds.centerY - 0.5)
        return bounds.area * max(0.2, 1.2 - distanceFromCenter)
    }

    private func makeSample(
        from observation: VNHumanBodyPoseObservation,
        captureUptime: TimeInterval,
        personCount: Int
    ) -> BodyPoseSample? {
        let mapping: [(BodyJoint, VNHumanBodyPoseObservation.JointName)] = [
            (.nose, .nose), (.neck, .neck), (.root, .root),
            (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
            (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
            (.leftHip, .leftHip), (.rightHip, .rightHip),
            (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
        ]
        var points: [BodyJoint: PosePoint] = [:]
        for (joint, visionName) in mapping {
            guard let point = try? observation.recognizedPoint(visionName), point.confidence >= 0.05 else { continue }
            points[joint] = PosePoint(
                x: Double(point.location.x),
                y: Double(point.location.y),
                confidence: Double(point.confidence)
            )
        }
        guard !points.isEmpty else { return nil }
        return BodyPoseSample(captureUptime: captureUptime, points: points, personCount: personCount)
    }
}

private final class SendablePoseSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer

    init(_ value: CMSampleBuffer) {
        self.value = value
    }
}

extension PoseRecognitionEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        processFrame(sampleBuffer)
    }
}
