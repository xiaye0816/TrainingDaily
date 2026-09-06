import Foundation

struct WorkoutConfig: Codable, Equatable, Sendable {
    var timerEnabled = true
    var durationSeconds = 60
    var autoStopAtTimerEnd = true

    var counterEnabled = true
    var countAnnouncementEnabled = false
    var countAnnouncementInterval = 5

    var timeAnnouncementEnabled = true
    var timeAnnouncementInterval = 10
    var finalCountdownEnabled = true

    var recordingEnabled = true
    var microphoneEnabled = true

    static let `default` = WorkoutConfig()

    var normalized: WorkoutConfig {
        var value = self
        value.durationSeconds = min(max(value.durationSeconds, 10), 3_600)
        value.timeAnnouncementInterval = min(max(value.timeAnnouncementInterval, 5), 300)
        value.countAnnouncementInterval = min(max(value.countAnnouncementInterval, 1), 100)

        if !value.timerEnabled {
            value.autoStopAtTimerEnd = false
            value.timeAnnouncementEnabled = false
            value.finalCountdownEnabled = false
        }
        if !value.counterEnabled {
            value.countAnnouncementEnabled = false
        }
        if !value.recordingEnabled {
            value.microphoneEnabled = false
        }
        return value
    }

    func shouldAnnounce(remainingSeconds: Int) -> Bool {
        guard timerEnabled, timeAnnouncementEnabled, remainingSeconds > 0 else { return false }
        if finalCountdownEnabled, remainingSeconds <= 5 {
            return true
        }
        return remainingSeconds < durationSeconds
            && remainingSeconds.isMultiple(of: timeAnnouncementInterval)
    }
}

extension Int {
    var clockText: String {
        let clamped = Swift.max(0, self)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}
