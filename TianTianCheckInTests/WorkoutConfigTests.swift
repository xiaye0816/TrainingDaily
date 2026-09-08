import XCTest
import UIKit
@testable import TianTianCheckIn

final class WorkoutConfigTests: XCTestCase {
    func testRootFlowShowsOneSecondSplashThenDismisses() {
        var flow = RootFlowState()

        XCTAssertTrue(flow.isShowingSplash)
        XCTAssertEqual(RootFlowState.splashDurationNanoseconds, 1_000_000_000)

        flow.dismissSplash()
        XCTAssertFalse(flow.isShowingSplash)
    }

    func testNativeLaunchScreenUsesLightStoryboardAndSharedAssets() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String,
            "LaunchScreen"
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "UIUserInterfaceStyle") as? String,
            "Light"
        )
        XCTAssertNotNil(UIImage(named: "SplashBackground"))
        XCTAssertNotNil(UIImage(named: "SplashBrand"))
        XCTAssertNotNil(UIImage(named: "SplashGlow"))
    }

    func testNormalizationClampsValuesAndDependencies() {
        var config = WorkoutConfig.default
        config.timerEnabled = false
        config.durationSeconds = 2
        config.timeAnnouncementInterval = 1
        config.counterEnabled = false
        config.countAnnouncementEnabled = true
        config.recordingEnabled = false
        config.microphoneEnabled = true

        let normalized = config.normalized

        XCTAssertEqual(normalized.durationSeconds, 10)
        XCTAssertEqual(normalized.timeAnnouncementInterval, 5)
        XCTAssertFalse(normalized.timeAnnouncementEnabled)
        XCTAssertFalse(normalized.finalCountdownEnabled)
        XCTAssertFalse(normalized.autoStopAtTimerEnd)
        XCTAssertFalse(normalized.countAnnouncementEnabled)
        XCTAssertFalse(normalized.microphoneEnabled)
    }

    func testAutomaticCountingRequiresCounterAndRecording() {
        var config = WorkoutConfig.default
        config.countingMode = .automatic
        config.recordingEnabled = false

        XCTAssertEqual(config.normalized.countingMode, .manual)

        config.recordingEnabled = true
        config.counterEnabled = false
        XCTAssertEqual(config.normalized.countingMode, .manual)
    }

    func testLegacyConfigurationDecodesWithoutResettingExistingValues() throws {
        let legacyJSON = Data(#"{"durationSeconds":90,"timerEnabled":true,"recordingEnabled":true,"microphoneEnabled":false}"#.utf8)

        let config = try JSONDecoder().decode(WorkoutConfig.self, from: legacyJSON)

        XCTAssertEqual(config.durationSeconds, 90)
        XCTAssertFalse(config.microphoneEnabled)
        XCTAssertEqual(config.exerciseType, .sitUp)
        XCTAssertEqual(config.countingMode, .manual)
    }

    func testDefaultTimeAnnouncementSchedule() {
        let config = WorkoutConfig.default

        XCTAssertTrue(config.shouldAnnounce(remainingSeconds: 50))
        XCTAssertTrue(config.shouldAnnounce(remainingSeconds: 10))
        XCTAssertTrue(config.shouldAnnounce(remainingSeconds: 5))
        XCTAssertTrue(config.shouldAnnounce(remainingSeconds: 1))
        XCTAssertFalse(config.shouldAnnounce(remainingSeconds: 59))
        XCTAssertFalse(config.shouldAnnounce(remainingSeconds: 60))
        XCTAssertFalse(config.shouldAnnounce(remainingSeconds: 0))
    }

    func testOverlayTimelineChangesAtCountEvent() {
        let events = [
            WorkoutEvent(offset: 0.4, kind: .countChanged(1)),
            WorkoutEvent(offset: 1.6, kind: .countChanged(2))
        ]

        let segments = OverlayTimelineBuilder.build(
            actualDuration: 3,
            configuredDuration: 60,
            timerEnabled: true,
            counterEnabled: true,
            events: events
        )

        XCTAssertEqual(segments.first?.remainingSeconds, 60)
        XCTAssertEqual(segments.first?.count, 0)
        XCTAssertEqual(segments.first(where: { $0.start == 0.4 })?.count, 1)
        XCTAssertEqual(segments.first(where: { $0.start == 1.6 })?.count, 2)
        XCTAssertEqual(segments.last?.remainingSeconds, 58)
    }

    func testOverlayCanHideDisabledMetrics() {
        let segments = OverlayTimelineBuilder.build(
            actualDuration: 2,
            configuredDuration: 60,
            timerEnabled: false,
            counterEnabled: true,
            events: []
        )

        XCTAssertNil(segments.first?.remainingSeconds)
        XCTAssertEqual(segments.first?.count, 0)
        XCTAssertEqual(segments.first?.label, "0 次")
    }

    func testPriorityAnnouncementDropsCountsUntilItFinishes() {
        var arbiter = SpeechAnnouncementArbiter()
        let speakingCount = UUID()
        let timeAnnouncement = UUID()

        XCTAssertTrue(arbiter.beginCount(token: speakingCount))

        arbiter.beginPriority(token: timeAnnouncement)

        XCTAssertTrue(arbiter.isPriorityActive)
        XCTAssertFalse(arbiter.beginCount(token: UUID()))

        // A delayed cancellation callback from the interrupted count must not
        // clear the newer time announcement.
        arbiter.finish(token: speakingCount)
        XCTAssertTrue(arbiter.isPriorityActive)

        arbiter.finish(token: timeAnnouncement)
        XCTAssertTrue(arbiter.beginCount(token: UUID()))
    }

    func testCountAnnouncementsAreNeverQueued() {
        var arbiter = SpeechAnnouncementArbiter()
        let firstCount = UUID()

        XCTAssertTrue(arbiter.beginCount(token: firstCount))
        XCTAssertFalse(arbiter.beginCount(token: UUID()))

        arbiter.finish(token: firstCount)
        XCTAssertTrue(arbiter.beginCount(token: UUID()))
    }

    func testSitUpCounterCountsOnlyCompleteCycles() {
        var counter = SitUpRepCounter()

        XCTAssertNil(counter.process(sitUpSample(uptime: 0.00, isUp: false)))
        XCTAssertNil(counter.process(sitUpSample(uptime: 0.08, isUp: false)))
        XCTAssertNil(counter.process(sitUpSample(uptime: 0.16, isUp: true)))
        XCTAssertNotNil(counter.process(sitUpSample(uptime: 0.24, isUp: true)))
        XCTAssertNil(counter.process(sitUpSample(uptime: 0.32, isUp: true)))
        XCTAssertNil(counter.process(sitUpSample(uptime: 0.40, isUp: false)))
        XCTAssertNil(counter.process(sitUpSample(uptime: 0.48, isUp: false)))
        XCTAssertNil(counter.process(sitUpSample(uptime: 0.72, isUp: true)))
        XCTAssertNotNil(counter.process(sitUpSample(uptime: 0.80, isUp: true)))
    }

    func testSitUpCounterDoesNotCountAnIncompleteMovement() {
        var counter = SitUpRepCounter()
        _ = counter.process(sitUpSample(uptime: 0, isUp: false))
        _ = counter.process(sitUpSample(uptime: 0.08, isUp: false))

        let partialPoints: [BodyJoint: PosePoint] = [
            .leftShoulder: point(0.35, 0.32),
            .leftHip: point(0.50, 0.20),
            .leftKnee: point(0.65, 0.38),
            .leftAnkle: point(0.78, 0.12)
        ]
        XCTAssertNil(counter.process(BodyPoseSample(captureUptime: 0.16, points: partialPoints, personCount: 1)))
        XCTAssertNil(counter.process(BodyPoseSample(captureUptime: 0.24, points: partialPoints, personCount: 1)))
    }

    func testSitUpCounterResetsAfterTrackingLoss() {
        var counter = SitUpRepCounter()
        _ = counter.process(sitUpSample(uptime: 0, isUp: false))
        _ = counter.process(sitUpSample(uptime: 0.08, isUp: false))
        _ = counter.process(sitUpSample(uptime: 0.16, isUp: true))
        counter.resetCycle()

        XCTAssertNil(counter.process(sitUpSample(uptime: 1.0, isUp: true)))
        XCTAssertNil(counter.process(sitUpSample(uptime: 1.08, isUp: true)))
    }

    func testJumpRopeCounterCountsLandingAndRejectsSmallJitter() {
        var counter = JumpRopeRepCounter()
        var detections = 0
        let sequence: [(TimeInterval, Double)] = [
            (0.00, 0.000), (0.07, 0.000),
            (0.14, 0.030), (0.21, 0.050), (0.28, 0.015),
            (0.35, 0.000), (0.42, 0.000), (0.49, 0.000)
        ]
        for (uptime, lift) in sequence {
            if counter.process(jumpRopeSample(uptime: uptime, lift: lift)) != nil {
                detections += 1
            }
        }
        XCTAssertEqual(detections, 1)

        for index in 0..<12 {
            let lift = index.isMultiple(of: 2) ? 0.008 : 0
            XCTAssertNil(counter.process(jumpRopeSample(uptime: 1 + Double(index) * 0.07, lift: lift)))
        }
    }

    func testPoseQualityRejectsMultiplePeopleAndAcceptsGuidedJumpRopeFrame() {
        var sample = jumpRopeSample(uptime: 0, lift: 0)
        XCTAssertNil(PoseQualityEvaluator.adjustment(for: sample, exercise: .jumpRope))

        sample = BodyPoseSample(captureUptime: 0, points: sample.points, personCount: 2)
        XCTAssertEqual(PoseQualityEvaluator.adjustment(for: sample, exercise: .jumpRope), .multiplePeople)
    }

    private func sitUpSample(uptime: TimeInterval, isUp: Bool) -> BodyPoseSample {
        let shoulder = isUp ? point(0.48, 0.62) : point(0.25, 0.20)
        return BodyPoseSample(
            captureUptime: uptime,
            points: [
                .leftShoulder: shoulder,
                .leftHip: point(0.50, 0.20),
                .leftKnee: point(0.65, 0.38),
                .leftAnkle: point(0.78, 0.12)
            ],
            personCount: 1
        )
    }

    private func jumpRopeSample(uptime: TimeInterval, lift: Double) -> BodyPoseSample {
        BodyPoseSample(
            captureUptime: uptime,
            points: [
                .nose: point(0.50, 0.91 + lift),
                .leftShoulder: point(0.40, 0.82 + lift),
                .rightShoulder: point(0.60, 0.82 + lift),
                .leftWrist: point(0.30, 0.55 + lift),
                .rightWrist: point(0.70, 0.55 + lift),
                .leftHip: point(0.44, 0.53 + lift),
                .rightHip: point(0.56, 0.53 + lift),
                .leftKnee: point(0.45, 0.32 + lift),
                .rightKnee: point(0.55, 0.32 + lift),
                .leftAnkle: point(0.45, 0.08 + lift),
                .rightAnkle: point(0.55, 0.08 + lift)
            ],
            personCount: 1
        )
    }

    private func point(_ x: Double, _ y: Double, confidence: Double = 0.95) -> PosePoint {
        PosePoint(x: x, y: y, confidence: confidence)
    }
}
