import XCTest
@testable import TianTianCheckIn

final class WorkoutConfigTests: XCTestCase {
    func testRootFlowShowsOneSecondSplashThenDismisses() {
        var flow = RootFlowState()

        XCTAssertTrue(flow.isShowingSplash)
        XCTAssertEqual(RootFlowState.splashDurationNanoseconds, 1_000_000_000)

        flow.dismissSplash()
        XCTAssertFalse(flow.isShowingSplash)
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
}
