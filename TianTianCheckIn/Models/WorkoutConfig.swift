import Foundation

enum ExerciseType: String, Codable, CaseIterable, Identifiable, Sendable {
    case sitUp
    case jumpRope

    var id: Self { self }

    var title: String {
        switch self {
        case .sitUp: "仰卧起坐"
        case .jumpRope: "一分钟跳绳"
        }
    }

    var icon: String {
        switch self {
        case .sitUp: "figure.core.training"
        case .jumpRope: "figure.jumprope"
        }
    }

    var framingInstruction: String {
        switch self {
        case .sitUp: "请将手机放在身体侧面，让训练者主体清晰入镜"
        case .jumpRope: "请正对手机站立，让训练者主体清晰入镜"
        }
    }
}

enum CountingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case automatic

    var id: Self { self }

    var title: String {
        switch self {
        case .manual: "手动计次"
        case .automatic: "自动计次"
        }
    }
}

private enum LegacyFinishSoundStyle: String, Codable, Sendable {
    case softWhistle
    case crispWhistle
    case doubleWhistle
    case gentleChime
    case off

}

enum AppFeatureAvailability {
    static let automaticCounting = true
}

struct WorkoutConfig: Codable, Equatable, Sendable {
    var timerEnabled = true
    var durationSeconds = 60
    var autoStopAtTimerEnd = true

    var counterEnabled = true
    var exerciseType = ExerciseType.sitUp
    var countingMode = CountingMode.manual
    var countAnnouncementEnabled = false
    var countAnnouncementInterval = 5

    var timeAnnouncementEnabled = true
    var timeAnnouncementInterval = 10
    var finalCountdownEnabled = true
    var stopAnnouncementEnabled = true

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
            value.countingMode = .manual
            value.countAnnouncementEnabled = false
        }
        if value.countingMode == .automatic, !AppFeatureAvailability.automaticCounting {
            value.countingMode = .manual
        }
        if !value.recordingEnabled {
            value.countingMode = .manual
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

enum WorkoutTimingPolicy {
    static let finishTailDuration: TimeInterval = 0.5

    static func announcementText(remainingSeconds: Int, finalCountdownEnabled: Bool) -> String {
        if finalCountdownEnabled, remainingSeconds <= 5 {
            return "\(remainingSeconds)"
        }
        return "\(remainingSeconds)秒"
    }
}

extension WorkoutConfig {
    private enum CodingKeys: String, CodingKey {
        case timerEnabled
        case durationSeconds
        case autoStopAtTimerEnd
        case counterEnabled
        case exerciseType
        case countingMode
        case countAnnouncementEnabled
        case countAnnouncementInterval
        case timeAnnouncementEnabled
        case timeAnnouncementInterval
        case finalCountdownEnabled
        case stopAnnouncementEnabled
        case finishSoundStyle
        case recordingEnabled
        case microphoneEnabled
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timerEnabled = try container.decodeIfPresent(Bool.self, forKey: .timerEnabled) ?? defaults.timerEnabled
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? defaults.durationSeconds
        autoStopAtTimerEnd = try container.decodeIfPresent(Bool.self, forKey: .autoStopAtTimerEnd) ?? defaults.autoStopAtTimerEnd
        counterEnabled = try container.decodeIfPresent(Bool.self, forKey: .counterEnabled) ?? defaults.counterEnabled
        exerciseType = try container.decodeIfPresent(ExerciseType.self, forKey: .exerciseType) ?? .sitUp
        countingMode = try container.decodeIfPresent(CountingMode.self, forKey: .countingMode) ?? .manual
        countAnnouncementEnabled = try container.decodeIfPresent(Bool.self, forKey: .countAnnouncementEnabled) ?? defaults.countAnnouncementEnabled
        countAnnouncementInterval = try container.decodeIfPresent(Int.self, forKey: .countAnnouncementInterval) ?? defaults.countAnnouncementInterval
        timeAnnouncementEnabled = try container.decodeIfPresent(Bool.self, forKey: .timeAnnouncementEnabled) ?? defaults.timeAnnouncementEnabled
        timeAnnouncementInterval = try container.decodeIfPresent(Int.self, forKey: .timeAnnouncementInterval) ?? defaults.timeAnnouncementInterval
        finalCountdownEnabled = try container.decodeIfPresent(Bool.self, forKey: .finalCountdownEnabled) ?? defaults.finalCountdownEnabled
        if let stopAnnouncementEnabled = try container.decodeIfPresent(Bool.self, forKey: .stopAnnouncementEnabled) {
            self.stopAnnouncementEnabled = stopAnnouncementEnabled
        } else if let legacyStyle = try container.decodeIfPresent(LegacyFinishSoundStyle.self, forKey: .finishSoundStyle) {
            stopAnnouncementEnabled = legacyStyle != .off
        } else {
            stopAnnouncementEnabled = defaults.stopAnnouncementEnabled
        }
        recordingEnabled = try container.decodeIfPresent(Bool.self, forKey: .recordingEnabled) ?? defaults.recordingEnabled
        microphoneEnabled = try container.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? defaults.microphoneEnabled
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timerEnabled, forKey: .timerEnabled)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(autoStopAtTimerEnd, forKey: .autoStopAtTimerEnd)
        try container.encode(counterEnabled, forKey: .counterEnabled)
        try container.encode(exerciseType, forKey: .exerciseType)
        try container.encode(countingMode, forKey: .countingMode)
        try container.encode(countAnnouncementEnabled, forKey: .countAnnouncementEnabled)
        try container.encode(countAnnouncementInterval, forKey: .countAnnouncementInterval)
        try container.encode(timeAnnouncementEnabled, forKey: .timeAnnouncementEnabled)
        try container.encode(timeAnnouncementInterval, forKey: .timeAnnouncementInterval)
        try container.encode(finalCountdownEnabled, forKey: .finalCountdownEnabled)
        try container.encode(stopAnnouncementEnabled, forKey: .stopAnnouncementEnabled)
        try container.encode(recordingEnabled, forKey: .recordingEnabled)
        try container.encode(microphoneEnabled, forKey: .microphoneEnabled)
    }
}

extension Int {
    var clockText: String {
        let clamped = Swift.max(0, self)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}
