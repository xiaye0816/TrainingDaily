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

enum PoseAnalysisOrientation: String, CaseIterable, Sendable {
    case upright
    case headOnLeft
    case headOnRight

    var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case .upright: .up
        case .headOnLeft: .right
        case .headOnRight: .left
        }
    }

    func canonicalPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        switch self {
        case .upright:
            (x, y)
        case .headOnLeft:
            (1 - y, x)
        case .headOnRight:
            (y, 1 - x)
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
        case .showFullBody: "请让训练者主体清晰入镜"
        case .showHead: "请露出头顶，并在上方留一点空间"
        case .showFeet: "请露出双脚，并在脚下留一点空间"
        case .moveCloser: "请靠近一些"
        case .moveFarther: "请离手机远一些"
        case .turnSideways: "请将身体侧面对准手机"
        case .faceCamera: "请正面对准手机"
        case .holdPosition: "位置合适，请保持"
        case .ready: "已识别主体，可以开始"
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
    struct Side: Sendable {
        let shoulder: PosePoint
        let hip: PosePoint
        let knee: PosePoint?
        let ankle: PosePoint?
    }

    static func adjustment(for sample: BodyPoseSample, exercise: ExerciseType) -> PoseTrackingStatus? {
        guard let bounds = sample.bounds else { return .findingPerson }

        switch exercise {
        case .sitUp:
            guard bestSide(in: sample) != nil else { return .showFullBody }
            if max(bounds.width, bounds.height) < 0.14 { return .moveCloser }
        case .jumpRope:
            if sample.point(.leftAnkle) == nil || sample.point(.rightAnkle) == nil { return .showFeet }
            let required: [BodyJoint] = [
                .leftShoulder, .rightShoulder,
                .leftHip, .rightHip, .leftAnkle, .rightAnkle
            ]
            guard required.allSatisfy({ sample.point($0) != nil }) else { return .showFullBody }
            if bounds.height < 0.20 { return .moveCloser }
        }
        return nil
    }

    static func bestSide(
        in sample: BodyPoseSample
    ) -> Side? {
        let left = side(in: sample, shoulder: .leftShoulder, hip: .leftHip, knee: .leftKnee, ankle: .leftAnkle)
        let right = side(in: sample, shoulder: .rightShoulder, hip: .rightHip, knee: .rightKnee, ankle: .rightAnkle)
        switch (left, right) {
        case let (.some(left), .some(right)):
            let leftConfidence = left.shoulder.confidence + left.hip.confidence + (left.knee?.confidence ?? 0) + (left.ankle?.confidence ?? 0)
            let rightConfidence = right.shoulder.confidence + right.hip.confidence + (right.knee?.confidence ?? 0) + (right.ankle?.confidence ?? 0)
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
    ) -> Side? {
        // Hands behind the head and loose hair frequently hide a shoulder
        // during sit-ups. Prefer the requested shoulder, but keep the torso
        // usable through a neck/head landmark when that shoulder is weak.
        guard let shoulderPoint = sample.point(shoulder, minimumConfidence: 0.12)
                ?? sample.point(.neck, minimumConfidence: 0.15)
                ?? sample.point(.nose, minimumConfidence: 0.20),
              let hipPoint = sample.point(hip, minimumConfidence: 0.12)
                ?? sample.point(.root, minimumConfidence: 0.15)
                ?? strongestPoint(in: sample, joints: [.leftHip, .rightHip], minimumConfidence: 0.12)
        else { return nil }
        return Side(
            shoulder: shoulderPoint,
            hip: hipPoint,
            knee: sample.point(knee, minimumConfidence: 0.12)
                ?? strongestPoint(in: sample, joints: [.leftKnee, .rightKnee], minimumConfidence: 0.12),
            ankle: sample.point(ankle, minimumConfidence: 0.12)
        )
    }

    static func sitUpAnalysisScore(for sample: BodyPoseSample) -> Double {
        guard let side = bestSide(in: sample), let bounds = sample.bounds else { return 0 }
        let confidence = side.shoulder.confidence + side.hip.confidence
            + (side.knee?.confidence ?? 0) * 0.6
        let completeness = side.knee == nil ? 0.65 : 1.0
        let size = min(1, max(bounds.width, bounds.height) / 0.35)
        return confidence * completeness * (0.65 + size * 0.35)
    }

    static func sitUpUpperPoint(in sample: BodyPoseSample) -> PosePoint? {
        if let neck = sample.point(.neck, minimumConfidence: 0.12) {
            return neck
        }
        if let left = sample.point(.leftShoulder, minimumConfidence: 0.12),
           let right = sample.point(.rightShoulder, minimumConfidence: 0.12) {
            return PosePoint(
                x: (left.x + right.x) / 2,
                y: (left.y + right.y) / 2,
                confidence: min(left.confidence, right.confidence)
            )
        }
        return strongestPoint(
            in: sample,
            joints: [.leftShoulder, .rightShoulder],
            minimumConfidence: 0.12
        ) ?? sample.point(.nose, minimumConfidence: 0.20)
    }

    private static func strongestPoint(
        in sample: BodyPoseSample,
        joints: [BodyJoint],
        minimumConfidence: Double
    ) -> PosePoint? {
        joints.compactMap { sample.point($0, minimumConfidence: minimumConfidence) }
            .max(by: { $0.confidence < $1.confidence })
    }

}

struct PrimaryPoseSubjectTracker {
    private var trackedBounds: PoseBounds?
    private var lastSeenUptime: TimeInterval?

    mutating func reset() {
        trackedBounds = nil
        lastSeenUptime = nil
    }

    mutating func select(
        from samples: [BodyPoseSample],
        at captureUptime: TimeInterval,
        canUpdateReference: (BodyPoseSample) -> Bool = { _ in true }
    ) -> BodyPoseSample? {
        guard !samples.isEmpty else { return nil }

        let selected: BodyPoseSample?
        if let trackedBounds,
           let lastSeenUptime,
           captureUptime - lastSeenUptime <= 1.2 {
            let matched = samples
                .map { ($0, trackingScore(candidate: $0.bounds, target: trackedBounds)) }
                .filter { $0.1 >= 0.18 }
                .max(by: { $0.1 < $1.1 })?.0
            // Vision can briefly collapse a horizontal body into a small torso
            // fragment. With only one candidate, keep returning it so quality
            // debouncing can bridge the gap, but never let it move the identity
            // reference unless it is a usable body pose.
            let onlyCandidate = samples.count == 1 ? samples[0] : nil
            let looselyMatched = onlyCandidate.flatMap {
                trackingScore(candidate: $0.bounds, target: trackedBounds) >= 0.08 ? $0 : nil
            }
            selected = matched ?? looselyMatched
        } else {
            selected = samples.max(by: { initialScore($0) < initialScore($1) })
        }

        guard let selected, let bounds = selected.bounds else { return nil }
        if canUpdateReference(selected) {
            trackedBounds = bounds
            lastSeenUptime = captureUptime
        }
        return selected
    }

    private func initialScore(_ sample: BodyPoseSample) -> Double {
        guard let bounds = sample.bounds else { return 0 }
        let distanceFromCenter = hypot(bounds.centerX - 0.5, bounds.centerY - 0.5)
        return bounds.area * max(0.2, 1.2 - distanceFromCenter)
    }

    private func trackingScore(candidate: PoseBounds?, target: PoseBounds) -> Double {
        guard let candidate else { return 0 }
        let distance = hypot(candidate.centerX - target.centerX, candidate.centerY - target.centerY)
        let proximity = max(0, 1 - distance / 0.45)
        let largestArea = max(candidate.area, target.area, 0.0001)
        let areaSimilarity = min(candidate.area, target.area) / largestArea
        return intersectionOverUnion(candidate, target) * 0.35 + proximity * 0.5 + areaSimilarity * 0.15
    }

    private func intersectionOverUnion(_ first: PoseBounds, _ second: PoseBounds) -> Double {
        let width = max(0, min(first.maxX, second.maxX) - max(first.minX, second.minX))
        let height = max(0, min(first.maxY, second.maxY) - max(first.minY, second.minY))
        let intersection = width * height
        return intersection / max(first.area + second.area - intersection, 0.0001)
    }
}

struct PoseOrientationSelector {
    private(set) var scores: [PoseAnalysisOrientation: Double] = [:]

    mutating func reset() {
        scores = [:]
    }

    mutating func observe(
        _ orientation: PoseAnalysisOrientation,
        samples: [BodyPoseSample]
    ) {
        let best = samples.map(PoseQualityEvaluator.sitUpAnalysisScore).max() ?? 0
        let fragmentationPenalty = samples.count > 1 ? 0.82 : 1.0
        let observed = best * fragmentationPenalty
        let previous = scores[orientation] ?? 0
        scores[orientation] = previous * 0.72 + observed * 0.28
    }

    var preferred: PoseAnalysisOrientation {
        PoseAnalysisOrientation.allCases.max {
            (scores[$0] ?? 0) < (scores[$1] ?? 0)
        } ?? .upright
    }

    var preferredSideways: PoseAnalysisOrientation {
        [PoseAnalysisOrientation.headOnLeft, .headOnRight].max {
            (scores[$0] ?? 0) < (scores[$1] ?? 0)
        } ?? .headOnLeft
    }

    var hasReliableFullPose: Bool {
        (scores[preferred] ?? 0) >= 0.65
    }
}

enum SitUpHeadDirection: String, Sendable {
    case left
    case right

    func progress(for point: PosePoint) -> Double {
        switch self {
        case .left: point.x
        case .right: -point.x
        }
    }
}

struct SitUpMotionCounter {
    private enum Phase: Equatable {
        case readyForUp
        case waitingForDown
    }

    private var phase = Phase.readyForUp
    private var direction: SitUpHeadDirection?
    private var downProgress: Double?
    private var bodyScale = 0.40
    private var previousProgress: Double?
    private var previousUpperPoint: PosePoint?
    private var previousUptime: TimeInterval?
    private var filteredProgress: Double?
    private var risingEvidenceUptime: TimeInterval?
    private var downStartedUptime: TimeInterval?
    private var postRepPeakProgress: Double?
    private var minimumProgressSinceRep: Double?
    private var hasDescentEvidence = false
    private var lastRepUptime = -Double.infinity
    private(set) var diagnosticDetail = "uncalibrated"

    mutating func calibrate(_ sample: BodyPoseSample, direction: SitUpHeadDirection) {
        guard let upper = PoseQualityEvaluator.sitUpUpperPoint(in: sample) else { return }
        setDirection(direction)
        let progress = direction.progress(for: upper)
        updateBodyScale(from: sample)
        if let downProgress {
            if progress < downProgress {
                self.downProgress = max(progress, downProgress - 0.035)
            } else if progress - downProgress < riseThreshold * 0.45 {
                self.downProgress = downProgress * 0.92 + progress * 0.08
            }
        } else {
            downProgress = progress
        }
        previousProgress = progress
        previousUpperPoint = upper
        previousUptime = sample.captureUptime
        filteredProgress = progress
    }

    mutating func process(
        _ sample: BodyPoseSample,
        direction: SitUpHeadDirection
    ) -> RepDetection? {
        guard let upper = PoseQualityEvaluator.sitUpUpperPoint(in: sample) else { return nil }
        setDirection(direction)
        updateBodyScale(from: sample)
        if let previousUpperPoint,
           let previousUptime,
           sample.captureUptime - previousUptime < 0.30,
           upper.distance(to: previousUpperPoint) > 0.18 {
            return nil
        }
        previousUpperPoint = upper
        previousUptime = sample.captureUptime
        let rawProgress = direction.progress(for: upper)
        let progress = filteredProgress.map { $0 * 0.52 + rawProgress * 0.48 } ?? rawProgress
        filteredProgress = progress
        guard let downProgress else {
            self.downProgress = progress
            previousProgress = progress
            return nil
        }

        let progressDelta = previousProgress.map { progress - $0 } ?? 0
        if progressDelta >= 0.008 {
            risingEvidenceUptime = sample.captureUptime
        }
        self.previousProgress = progress
        let displacement = progress - downProgress
        diagnosticDetail = String(
            format: "progress=%.3f,baseline=%.3f,displacement=%.3f,threshold=%.3f,phase=%@",
            progress,
            downProgress,
            displacement,
            riseThreshold,
            phase == .readyForUp ? "ready" : "waitingDown"
        )

        switch phase {
        case .readyForUp:
            if displacement <= riseThreshold * 0.45 {
                self.downProgress = self.downProgress.map { min($0, progress) } ?? progress
            }
            guard displacement >= riseThreshold,
                  let risingEvidenceUptime,
                  sample.captureUptime - risingEvidenceUptime <= 0.25,
                  sample.captureUptime - lastRepUptime >= 0.45 else { return nil }
            phase = .waitingForDown
            downStartedUptime = nil
            postRepPeakProgress = progress
            minimumProgressSinceRep = progress
            hasDescentEvidence = false
            lastRepUptime = sample.captureUptime
            return RepDetection(
                captureUptime: sample.captureUptime,
                exercise: .sitUp,
                confidence: min(0.82, max(0.45, upper.confidence))
            )
        case .waitingForDown:
            postRepPeakProgress = max(postRepPeakProgress ?? progress, progress)
            let dropFromPeak = (postRepPeakProgress ?? progress) - progress
            if !hasDescentEvidence,
               dropFromPeak >= riseThreshold * 1.20 {
                hasDescentEvidence = true
                minimumProgressSinceRep = progress
            }
            guard hasDescentEvidence else { return nil }
            minimumProgressSinceRep = min(minimumProgressSinceRep ?? progress, progress)
            let localMinimum = minimumProgressSinceRep ?? progress
            let isClearlyBackDown = displacement <= riseThreshold * 0.50
                || (dropFromPeak >= riseThreshold * 1.20 && progress - localMinimum <= 0.018)
            let hasStartedNextRise = progress - localMinimum >= 0.010
                && progressDelta >= 0.006

            if hasStartedNextRise {
                phase = .readyForUp
                self.downProgress = localMinimum
                risingEvidenceUptime = sample.captureUptime
                downStartedUptime = nil
                postRepPeakProgress = nil
                minimumProgressSinceRep = nil
                hasDescentEvidence = false
                return nil
            }
            guard isClearlyBackDown else {
                downStartedUptime = nil
                return nil
            }
            if downStartedUptime == nil {
                downStartedUptime = sample.captureUptime
                return nil
            }
            guard sample.captureUptime - (downStartedUptime ?? sample.captureUptime) >= 0.10 else {
                return nil
            }
            phase = .readyForUp
            self.downProgress = min(downProgress, progress)
            risingEvidenceUptime = nil
            downStartedUptime = nil
            postRepPeakProgress = nil
            minimumProgressSinceRep = nil
            hasDescentEvidence = false
            return nil
        }
    }

    mutating func resetCycle(keepCalibration: Bool) {
        phase = .readyForUp
        previousProgress = nil
        previousUpperPoint = nil
        previousUptime = nil
        filteredProgress = nil
        risingEvidenceUptime = nil
        downStartedUptime = nil
        postRepPeakProgress = nil
        minimumProgressSinceRep = nil
        hasDescentEvidence = false
        if !keepCalibration {
            direction = nil
            downProgress = nil
            bodyScale = 0.40
        }
    }

    private var riseThreshold: Double {
        min(0.11, max(0.060, bodyScale * 0.18))
    }

    private mutating func setDirection(_ next: SitUpHeadDirection) {
        guard direction != next else { return }
        direction = next
        downProgress = nil
        phase = .readyForUp
        previousProgress = nil
        previousUpperPoint = nil
        previousUptime = nil
        filteredProgress = nil
        risingEvidenceUptime = nil
        downStartedUptime = nil
        postRepPeakProgress = nil
        minimumProgressSinceRep = nil
        hasDescentEvidence = false
    }

    private mutating func updateBodyScale(from sample: BodyPoseSample) {
        guard let side = PoseQualityEvaluator.bestSide(in: sample) else { return }
        let torso = side.shoulder.distance(to: side.hip)
        let lower = side.knee.map { side.hip.distance(to: $0) } ?? torso * 0.8
        let measured = min(0.65, max(0.20, torso + lower))
        bodyScale = bodyScale * 0.8 + measured * 0.2
    }
}

final class SitUpVisualTracker {
    private var sequenceHandler = VNSequenceRequestHandler()
    private var observation: VNDetectedObjectObservation?

    var isTracking: Bool { observation != nil }

    func reset() {
        observation = nil
        sequenceHandler = VNSequenceRequestHandler()
    }

    func seed(from sample: BodyPoseSample) -> Bool {
        guard let upper = PoseQualityEvaluator.sitUpUpperPoint(in: sample),
              let bounds = sample.bounds else { return false }
        let span = max(bounds.width, bounds.height)
        let width = min(0.30, max(0.18, span * 0.50))
        let height = min(0.28, max(0.16, span * 0.45))
        let center: (x: Double, y: Double) = {
            guard let side = PoseQualityEvaluator.bestSide(in: sample) else {
                return (upper.x, upper.y)
            }
            let dx = side.hip.x - upper.x
            let direction = dx == 0 ? 0 : dx / abs(dx)
            let inset = min(0.03, abs(dx) * 0.15)
            return (upper.x + direction * inset, upper.y)
        }()
        let rect = CGRect(
            x: min(max(center.x - width / 2, 0), 1 - width),
            y: min(max(center.y - height / 2, 0), 1 - height),
            width: width,
            height: height
        )
        sequenceHandler = VNSequenceRequestHandler()
        observation = VNDetectedObjectObservation(boundingBox: rect)
        return true
    }

    func track(
        pixelBuffer: CVPixelBuffer,
        captureUptime: TimeInterval
    ) -> BodyPoseSample? {
        guard let observation else { return nil }
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
            guard let result = request.results?.first as? VNDetectedObjectObservation,
                  result.confidence >= 0.25 else {
                reset()
                return nil
            }
            self.observation = result
            let bounds = result.boundingBox
            return BodyPoseSample(
                captureUptime: captureUptime,
                points: [
                    .neck: PosePoint(
                        x: bounds.midX,
                        y: bounds.midY,
                        confidence: Double(result.confidence)
                    )
                ],
                personCount: 1
            )
        } catch {
            reset()
            return nil
        }
    }
}

struct SitUpRepCounter {
    struct Thresholds {
        var downMaximumTorsoAngle = 18.0
        var downMaximumShoulderHeight = 0.18
        var upMinimumTorsoAngle = 20.0
        var minimumShoulderRise = 0.07
        var downStableSampleCount = 1
        var minimumRepInterval = 0.45
        var inferredDownMinimumLossDuration = 0.25
        var inferredDownMaximumLossDuration = 1.2
        var descendingAngleDrop = 12.0
        var descendingMaximumAngle = 48.0
        var descentEvidenceLifetime = 0.5
    }

    private enum Phase {
        case seekingDown
        case readyForUp
        case waitingForDown
    }

    private var phase = Phase.seekingDown
    private var stableSamples = 0
    private var lastRepUptime = -Double.infinity
    private var downHip: PosePoint?
    private var downBodyScale = 0.1
    private var downShoulderHeight = 0.0
    private var postRepPeakAngle = 0.0
    private var descentEvidenceUptime: TimeInterval?
    private var poseUnavailableSince: TimeInterval?
    private let thresholds: Thresholds

    init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    mutating func process(_ sample: BodyPoseSample) -> RepDetection? {
        guard let side = PoseQualityEvaluator.bestSide(in: sample) else {
            return nil
        }
        let torsoLength = side.shoulder.distance(to: side.hip)
        let lowerBodyLength = side.knee.map { side.hip.distance(to: $0) } ?? torsoLength * 0.8
        let bodyScale = max(torsoLength + lowerBodyLength, 0.08)
        let rawAngle = abs(atan2(side.shoulder.y - side.hip.y, side.shoulder.x - side.hip.x))
        let torsoAngle = min(rawAngle, abs(.pi - rawAngle)) * 180 / .pi
        let shoulderHeight = (side.shoulder.y - side.hip.y) / bodyScale
        let isDown = torsoAngle <= thresholds.downMaximumTorsoAngle
            && shoulderHeight <= thresholds.downMaximumShoulderHeight
        let hipDisplacement = downHip.map { side.hip.distance(to: $0) / max(downBodyScale, 0.08) } ?? 0
        let bodyAlignedStanding: Bool = {
            guard let knee = side.knee else { return false }
            let first = CGVector(dx: side.shoulder.x - side.hip.x, dy: side.shoulder.y - side.hip.y)
            let second = CGVector(dx: knee.x - side.hip.x, dy: knee.y - side.hip.y)
            let lengths = hypot(first.dx, first.dy) * hypot(second.dx, second.dy)
            guard lengths > 0.0001 else { return false }
            let cosine = min(1, max(-1, (first.dx * second.dx + first.dy * second.dy) / lengths))
            return acos(cosine) * 180 / .pi >= 155
        }()
        let isStanding = hipDisplacement > 0.42 || bodyAlignedStanding
        let isUp = torsoAngle >= thresholds.upMinimumTorsoAngle
            && shoulderHeight - downShoulderHeight >= thresholds.minimumShoulderRise
            && !isStanding

        let unavailableDuration = poseUnavailableSince.map { sample.captureUptime - $0 }
        poseUnavailableSince = nil

        if case .waitingForDown = phase {
            postRepPeakAngle = max(postRepPeakAngle, torsoAngle)
            if torsoAngle <= thresholds.descendingMaximumAngle,
               postRepPeakAngle - torsoAngle >= thresholds.descendingAngleDrop {
                descentEvidenceUptime = sample.captureUptime
            }

            // When the body reaches the bed, the hands and hair can hide the
            // torso. Infer that down transition only if a descent was already
            // visible before a short gap. Reappearing by itself never arms a
            // new repetition.
            if let unavailableDuration,
               unavailableDuration >= thresholds.inferredDownMinimumLossDuration,
               unavailableDuration <= thresholds.inferredDownMaximumLossDuration,
               let descentEvidenceUptime,
               sample.captureUptime - descentEvidenceUptime <= thresholds.descentEvidenceLifetime + unavailableDuration,
               torsoAngle <= thresholds.descendingMaximumAngle {
                phase = .readyForUp
                downHip = side.hip
                downBodyScale = bodyScale
                downShoulderHeight = min(shoulderHeight, thresholds.downMaximumShoulderHeight)
                stableSamples = 0
                self.descentEvidenceUptime = nil
                return nil
            }
        }

        switch phase {
        case .seekingDown, .waitingForDown:
            stableSamples = isDown ? stableSamples + 1 : 0
            if stableSamples >= thresholds.downStableSampleCount {
                phase = .readyForUp
                downHip = side.hip
                downBodyScale = bodyScale
                downShoulderHeight = shoulderHeight
                stableSamples = 0
            }
        case .readyForUp:
            guard isUp,
                  sample.captureUptime - lastRepUptime >= thresholds.minimumRepInterval else { return nil }
            phase = .waitingForDown
            stableSamples = 0
            lastRepUptime = sample.captureUptime
            postRepPeakAngle = torsoAngle
            descentEvidenceUptime = nil
            let confidencePoints = [side.shoulder, side.hip] + [side.knee, side.ankle].compactMap { $0 }
            let confidence = confidencePoints
                .map(\.confidence)
                .reduce(0, +) / Double(confidencePoints.count)
            return RepDetection(captureUptime: sample.captureUptime, exercise: .sitUp, confidence: confidence)
        }
        return nil
    }

    mutating func notePoseUnavailable(at uptime: TimeInterval) {
        if poseUnavailableSince == nil {
            poseUnavailableSince = uptime
        }
    }

    mutating func resetCycle() {
        phase = .seekingDown
        stableSamples = 0
        downHip = nil
        downShoulderHeight = 0
        postRepPeakAngle = 0
        descentEvidenceUptime = nil
        poseUnavailableSince = nil
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

    mutating func notePoseUnavailable(at uptime: TimeInterval) {
        switch self {
        case var .sitUp(counter):
            counter.notePoseUnavailable(at: uptime)
            self = .sitUp(counter)
        case .jumpRope:
            break
        }
    }
}

struct PoseTrackingDebouncer {
    enum Transition: Equatable {
        case none
        case lost
        case tracking
    }

    private(set) var isShowingLost = false
    private var lossStartedUptime: TimeInterval?
    private var recoverySampleCount = 0
    private let lossGraceDuration: TimeInterval
    private let requiredRecoverySamples: Int

    init(lossGraceDuration: TimeInterval = 1.2, requiredRecoverySamples: Int = 2) {
        self.lossGraceDuration = lossGraceDuration
        self.requiredRecoverySamples = requiredRecoverySamples
    }

    mutating func noteMissing(at uptime: TimeInterval) -> Transition {
        if lossStartedUptime == nil {
            lossStartedUptime = uptime
        }
        recoverySampleCount = 0
        guard !isShowingLost,
              uptime - (lossStartedUptime ?? uptime) >= lossGraceDuration else { return .none }
        isShowingLost = true
        return .lost
    }

    mutating func noteUsable() -> Transition {
        lossStartedUptime = nil
        guard isShowingLost else {
            recoverySampleCount = 0
            return .none
        }
        recoverySampleCount += 1
        guard recoverySampleCount >= requiredRecoverySamples else { return .none }
        isShowingLost = false
        recoverySampleCount = 0
        return .tracking
    }

    mutating func reset() {
        isShowingLost = false
        lossStartedUptime = nil
        recoverySampleCount = 0
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
    private var diagnosticsRecorder: WorkoutDiagnosticsRecorder?
    private var lastStatus = PoseTrackingStatus.inactive
    private var framingHasUsableSubject = false
    private var subjectTracker = PrimaryPoseSubjectTracker()
    private var lastAnalyzedUptime = -Double.infinity
    private var trackingDebouncer = PoseTrackingDebouncer()
    private var lastPoseQualityDetail: String?
    private var processedFrameTimes: [TimeInterval] = []
    private var didResetForCurrentLoss = false
    private var orientationSelector = PoseOrientationSelector()
    private var activeOrientation = PoseAnalysisOrientation.upright
    private var analysisFrameIndex = 0
    private var lastPrimaryUsableUptime = -Double.infinity
    private var alternateRecoveryCounts: [PoseAnalysisOrientation: Int] = [:]
    private var lastOrientationScoreLog: [PoseAnalysisOrientation: TimeInterval] = [:]
    private var cameraIsMirrored = false
    private var sitUpMotionCounter = SitUpMotionCounter()
    private let sitUpVisualTracker = SitUpVisualTracker()
    private var inferredHeadDirection: SitUpHeadDirection?
    private var activeHeadDirection = SitUpHeadDirection.left
    private var prefersVisualSitUpCounting = false
    private var lastEmittedRepUptime = -Double.infinity
    private var lastMotionDiagnosticUptime = -Double.infinity
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
            autoreleasepool {
                self.processFrame(reference.value)
            }
            submissionLock.lock()
            hasPendingFrame = false
            submissionLock.unlock()
        }
    }

    func configure(
        exercise: ExerciseType,
        diagnosticsRecorder: WorkoutDiagnosticsRecorder? = nil,
        statusHandler: @escaping StatusHandler,
        detectionHandler: @escaping DetectionHandler
    ) {
        captureQueue.sync {
            self.exercise = exercise
            counter = ExerciseCounter(exercise: exercise)
            self.statusHandler = statusHandler
            self.detectionHandler = detectionHandler
            self.diagnosticsRecorder = diagnosticsRecorder
            mode = .framing
            resetAnalysisState()
            emit(.findingPerson)
        }
    }

    func beginCounting(activeStartUptime: TimeInterval) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            counter = ExerciseCounter(exercise: exercise)
            activeOrientation = exercise == .sitUp ? orientationSelector.preferred : .upright
            activeHeadDirection = resolvedHeadDirection()
            prefersVisualSitUpCounting = exercise == .sitUp
                && !orientationSelector.hasReliableFullPose
            sitUpMotionCounter.resetCycle(keepCalibration: true)
            lastEmittedRepUptime = -Double.infinity
            mode = .counting(activeStartUptime: activeStartUptime)
            processedFrameTimes = []
            trackingDebouncer.reset()
            didResetForCurrentLoss = false
            lastPrimaryUsableUptime = activeStartUptime
            alternateRecoveryCounts = [:]
            diagnosticsRecorder?.recordEvent(
                "orientation_selected",
                detail: "orientation=\(activeOrientation.rawValue),mirrored=\(cameraIsMirrored),counter=\(prefersVisualSitUpCounting ? "visual" : "pose")",
                uptime: activeStartUptime
            )
            emit(.tracking)
        }
    }

    func updateCameraMirroring(isMirrored: Bool) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            cameraIsMirrored = isMirrored
            diagnosticsRecorder?.recordEvent("camera_mirroring", detail: "mirrored=\(isMirrored)")
        }
    }

    func pause() {
        captureQueue.async { [weak self] in
            self?.mode = .inactive
        }
    }

    func pauseAndDrain() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.mode = .inactive
                continuation.resume()
            }
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
            diagnosticsRecorder = nil
            resetAnalysisState()
        }
    }

    private func resetAnalysisState() {
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        framingHasUsableSubject = false
        subjectTracker.reset()
        lastAnalyzedUptime = -Double.infinity
        trackingDebouncer.reset()
        lastPoseQualityDetail = nil
        processedFrameTimes = []
        didResetForCurrentLoss = false
        orientationSelector.reset()
        activeOrientation = .upright
        analysisFrameIndex = 0
        lastPrimaryUsableUptime = -Double.infinity
        alternateRecoveryCounts = [:]
        lastOrientationScoreLog = [:]
        sitUpMotionCounter = SitUpMotionCounter()
        sitUpVisualTracker.reset()
        inferredHeadDirection = nil
        activeHeadDirection = .left
        prefersVisualSitUpCounting = false
        lastEmittedRepUptime = -Double.infinity
        lastMotionDiagnosticUptime = -Double.infinity
    }

    private func emit(_ status: PoseTrackingStatus) {
        guard status != lastStatus else { return }
        lastStatus = status
        diagnosticsRecorder?.recordEvent("pose_status", detail: status.message)
        statusHandler?(status)
    }

    private func processFrame(_ sampleBuffer: CMSampleBuffer) {
        if case .inactive = mode { return }

        let captureUptime = Self.captureUptime(for: sampleBuffer)
        guard captureUptime - lastAnalyzedUptime >= 1.0 / 15.0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalyzedUptime = captureUptime

        if case .counting = mode {
            recordProcessedFrame(at: captureUptime)
        }

        let shouldUseVisualTracker: Bool = {
            guard exercise == .sitUp, sitUpVisualTracker.isTracking else { return false }
            if case .framing = mode { return true }
            return prefersVisualSitUpCounting
        }()
        if shouldUseVisualTracker {
            processVisualTrackingFrame(pixelBuffer, captureUptime: captureUptime)
            // Object tracking is deliberately kept at the full 15 fps. It is
            // much cheaper than pose estimation and needs the temporal density
            // to avoid drifting during fast repetitions. Refresh the skeleton
            // every third frame to validate/reseed the tracked subject.
            guard analysisFrameIndex % 3 == 0 else {
                analysisFrameIndex += 1
                return
            }
        }

        let orientation = nextAnalysisOrientation(at: captureUptime)
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation.imageOrientation
        )
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            handleObservations(
                observations,
                orientation: orientation,
                captureUptime: captureUptime
            )
        } catch {
            diagnosticsRecorder?.recordEvent(
                "vision_error",
                detail: "orientation=\(orientation.rawValue),error=\(error.localizedDescription)",
                uptime: captureUptime
            )
            handleMissingPose(
                at: captureUptime,
                detail: "vision_error,orientation=\(orientation.rawValue)"
            )
        }
    }

    private func nextAnalysisOrientation(at captureUptime: TimeInterval) -> PoseAnalysisOrientation {
        defer { analysisFrameIndex += 1 }
        guard exercise == .sitUp else { return .upright }
        switch mode {
        case .framing:
            return PoseAnalysisOrientation.allCases[analysisFrameIndex % PoseAnalysisOrientation.allCases.count]
        case .counting:
            if captureUptime - lastPrimaryUsableUptime > 0.35 {
                return PoseAnalysisOrientation.allCases[analysisFrameIndex % PoseAnalysisOrientation.allCases.count]
            }
            let sidewaysFallback = orientationSelector.preferredSideways
            let pattern = activeOrientation == .upright
                ? [PoseAnalysisOrientation.upright, .upright, sidewaysFallback]
                : [activeOrientation, activeOrientation, .upright]
            return pattern[analysisFrameIndex % pattern.count]
        case .inactive:
            return .upright
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

    private func processVisualTrackingFrame(
        _ pixelBuffer: CVPixelBuffer,
        captureUptime: TimeInterval
    ) {
        guard let sample = sitUpVisualTracker.track(
            pixelBuffer: pixelBuffer,
            captureUptime: captureUptime
        ) else {
            diagnosticsRecorder?.recordEvent(
                "visual_tracker_lost",
                uptime: captureUptime
            )
            handleMissingPose(at: captureUptime, detail: "visual_tracker_lost")
            return
        }

        switch mode {
        case .framing:
            sitUpMotionCounter.calibrate(sample, direction: resolvedHeadDirection())
            if framingHasUsableSubject {
                emit(.ready)
            }
        case let .counting(activeStartUptime):
            guard case .counting = mode, captureUptime >= activeStartUptime else { return }
            didResetForCurrentLoss = false
            emitPoseQuality("visual_tracking", uptime: captureUptime)
            if trackingDebouncer.noteUsable() == .tracking {
                emit(.tracking)
            }
            let detection = sitUpMotionCounter.process(
                sample,
                direction: activeHeadDirection
            )
            if captureUptime - lastMotionDiagnosticUptime >= 0.5 {
                lastMotionDiagnosticUptime = captureUptime
                diagnosticsRecorder?.recordEvent(
                    "sit_up_motion",
                    detail: "direction=\(activeHeadDirection.rawValue),\(sitUpMotionCounter.diagnosticDetail)",
                    uptime: captureUptime
                )
            }
            if prefersVisualSitUpCounting {
                emitDetectionIfNeeded(detection)
            }
        case .inactive:
            break
        }
    }

    private func handleObservations(
        _ observations: [VNHumanBodyPoseObservation],
        orientation: PoseAnalysisOrientation,
        captureUptime: TimeInterval
    ) {
        let samples = observations.compactMap {
            makeSample(
                from: $0,
                orientation: orientation,
                captureUptime: captureUptime,
                personCount: observations.count
            )
        }
        if exercise == .sitUp {
            orientationSelector.observe(orientation, samples: samples)
            logOrientationScoreIfNeeded(orientation, samples: samples, uptime: captureUptime)
        }
        switch mode {
        case .framing:
            request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
            let tracked = subjectTracker.select(
                from: samples,
                at: captureUptime,
                canUpdateReference: { PoseQualityEvaluator.adjustment(for: $0, exercise: self.exercise) == nil }
            )
            let selected = tracked.flatMap {
                PoseQualityEvaluator.adjustment(for: $0, exercise: exercise) == nil ? $0 : nil
            }
            diagnosticsRecorder?.recordPose(samples: samples, selected: selected)
            if exercise == .sitUp, let tracked {
                updateInferredHeadDirection(from: tracked)
                if !sitUpVisualTracker.isTracking,
                   PoseQualityEvaluator.adjustment(for: tracked, exercise: .sitUp) == nil,
                   sitUpVisualTracker.seed(from: tracked) {
                    diagnosticsRecorder?.recordEvent(
                        "visual_tracker_seeded",
                        detail: "direction=\(resolvedHeadDirection().rawValue)",
                        uptime: captureUptime
                    )
                }
            }
            if selected != nil {
                framingHasUsableSubject = true
            }
            if framingHasUsableSubject {
                emit(.ready)
            } else {
                let guidanceCandidate = samples.max(by: { ($0.bounds?.area ?? 0) < ($1.bounds?.area ?? 0) })
                emit(guidanceCandidate.flatMap { PoseQualityEvaluator.adjustment(for: $0, exercise: exercise) } ?? .findingPerson)
            }
        case let .counting(activeStartUptime):
            guard case .counting = mode else { return }
            guard captureUptime >= activeStartUptime else { return }
            guard let tracked = subjectTracker.select(
                from: samples,
                at: captureUptime,
                canUpdateReference: { PoseQualityEvaluator.adjustment(for: $0, exercise: self.exercise) == nil }
            ) else {
                diagnosticsRecorder?.recordPose(samples: samples, selected: nil)
                handleMissingPose(
                    at: captureUptime,
                    detail: (samples.isEmpty ? "no_person" : "subject_not_matched")
                        + ",orientation=\(orientation.rawValue)"
                )
                return
            }
            let hasStableUpperBody: Bool
            if exercise == .sitUp,
               PoseQualityEvaluator.sitUpUpperPoint(in: tracked) != nil {
                hasStableUpperBody = true
                if !sitUpVisualTracker.isTracking,
                   PoseQualityEvaluator.adjustment(for: tracked, exercise: .sitUp) == nil,
                   sitUpVisualTracker.seed(from: tracked) {
                    diagnosticsRecorder?.recordEvent(
                        "visual_tracker_seeded",
                        detail: "direction=\(activeHeadDirection.rawValue)",
                        uptime: captureUptime
                    )
                }
                noteUsableOrientation(orientation, at: captureUptime)
                didResetForCurrentLoss = false
                if trackingDebouncer.noteUsable() == .tracking {
                    emit(.tracking)
                }
            } else {
                hasStableUpperBody = false
            }

            guard PoseQualityEvaluator.adjustment(for: tracked, exercise: exercise) == nil else {
                diagnosticsRecorder?.recordPose(samples: samples, selected: tracked)
                if hasStableUpperBody {
                    emitPoseQuality(
                        "upper_body_fallback,orientation=\(orientation.rawValue)",
                        uptime: captureUptime
                    )
                    return
                }
                handleMissingPose(
                    at: captureUptime,
                    detail: "partial_pose,orientation=\(orientation.rawValue)"
                )
                return
            }
            diagnosticsRecorder?.recordPose(samples: samples, selected: tracked)
            noteUsableOrientation(orientation, at: captureUptime)
            didResetForCurrentLoss = false
            emitPoseQuality("usable,orientation=\(orientation.rawValue)", uptime: captureUptime)
            if trackingDebouncer.noteUsable() == .tracking {
                emit(.tracking)
            }
            if exercise != .sitUp || !prefersVisualSitUpCounting {
                let poseDetection = counter.process(tracked)
                emitDetectionIfNeeded(poseDetection)
            }
        case .inactive:
            break
        }
    }

    private func handleMissingPose(at captureUptime: TimeInterval, detail: String = "no_person") {
        switch mode {
        case .framing:
            emit(framingHasUsableSubject ? .ready : .findingPerson)
        case .counting:
            counter.notePoseUnavailable(at: captureUptime)
            emitPoseQuality(detail, uptime: captureUptime)
            if trackingDebouncer.noteMissing(at: captureUptime) == .lost {
                emit(.lost)
            }
            guard trackingDebouncer.isShowingLost else { return }
            if !didResetForCurrentLoss {
                counter.resetCycle()
                sitUpMotionCounter.resetCycle(keepCalibration: true)
                didResetForCurrentLoss = true
            }
            request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        case .inactive:
            break
        }
    }

    private func emitPoseQuality(_ detail: String, uptime: TimeInterval) {
        guard detail != lastPoseQualityDetail else { return }
        lastPoseQualityDetail = detail
        diagnosticsRecorder?.recordEvent("pose_quality", detail: detail, uptime: uptime)
    }

    private func recordProcessedFrame(at captureUptime: TimeInterval) {
        guard processedFrameTimes.last != captureUptime else { return }
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

    private func makeSample(
        from observation: VNHumanBodyPoseObservation,
        orientation: PoseAnalysisOrientation,
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
            let canonical = orientation.canonicalPoint(
                x: Double(point.location.x),
                y: Double(point.location.y)
            )
            points[joint] = PosePoint(
                x: canonical.x,
                y: canonical.y,
                confidence: Double(point.confidence)
            )
        }
        guard !points.isEmpty else { return nil }
        return BodyPoseSample(captureUptime: captureUptime, points: points, personCount: personCount)
    }

    private func noteUsableOrientation(
        _ orientation: PoseAnalysisOrientation,
        at captureUptime: TimeInterval
    ) {
        guard exercise == .sitUp else { return }
        if orientation == activeOrientation {
            lastPrimaryUsableUptime = captureUptime
            alternateRecoveryCounts = [:]
            return
        }
        guard captureUptime - lastPrimaryUsableUptime > 0.35 else { return }
        alternateRecoveryCounts[orientation, default: 0] += 1
        guard alternateRecoveryCounts[orientation, default: 0] >= 2 else { return }
        activeOrientation = orientation
        lastPrimaryUsableUptime = captureUptime
        alternateRecoveryCounts = [:]
        diagnosticsRecorder?.recordEvent(
            "orientation_switched",
            detail: "orientation=\(orientation.rawValue),mirrored=\(cameraIsMirrored)",
            uptime: captureUptime
        )
    }

    private func updateInferredHeadDirection(from sample: BodyPoseSample) {
        guard let side = PoseQualityEvaluator.bestSide(in: sample),
              abs(side.shoulder.x - side.hip.x) >= 0.04 else { return }
        inferredHeadDirection = side.shoulder.x < side.hip.x ? .left : .right
    }

    private func resolvedHeadDirection() -> SitUpHeadDirection {
        let leftScore = orientationSelector.scores[.headOnLeft] ?? 0
        let rightScore = orientationSelector.scores[.headOnRight] ?? 0
        if max(leftScore, rightScore) >= 0.08,
           abs(leftScore - rightScore) >= 0.03 {
            return leftScore > rightScore ? .left : .right
        }
        return inferredHeadDirection
            ?? (orientationSelector.preferredSideways == .headOnLeft ? .left : .right)
    }

    private func emitDetectionIfNeeded(_ detection: RepDetection?) {
        guard let detection,
              detection.captureUptime - lastEmittedRepUptime >= 0.45 else { return }
        lastEmittedRepUptime = detection.captureUptime
        diagnosticsRecorder?.recordEvent(
            "rep_detected",
            detail: "confidence=\(detection.confidence),direction=\(activeHeadDirection.rawValue)",
            uptime: detection.captureUptime
        )
        detectionHandler?(detection)
    }

    private func logOrientationScoreIfNeeded(
        _ orientation: PoseAnalysisOrientation,
        samples: [BodyPoseSample],
        uptime: TimeInterval
    ) {
        guard uptime - (lastOrientationScoreLog[orientation] ?? -Double.infinity) >= 1 else { return }
        lastOrientationScoreLog[orientation] = uptime
        let score = samples.map(PoseQualityEvaluator.sitUpAnalysisScore).max() ?? 0
        diagnosticsRecorder?.recordEvent(
            "orientation_score",
            detail: "orientation=\(orientation.rawValue),score=\(String(format: "%.3f", score)),people=\(samples.count)",
            uptime: uptime
        )
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
