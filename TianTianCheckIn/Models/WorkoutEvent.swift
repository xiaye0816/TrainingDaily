import Foundation

enum WorkoutEndReason: String, Codable, Sendable {
    case timerFinished
    case manual
    case interrupted
}

enum WorkoutEventKind: Equatable, Codable, Sendable {
    case countChanged(Int)
    case announcement(String)

    private enum CodingKeys: String, CodingKey { case type, count, text }
    private enum Kind: String, Codable { case countChanged, announcement }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .countChanged:
            self = .countChanged(try container.decode(Int.self, forKey: .count))
        case .announcement:
            self = .announcement(try container.decode(String.self, forKey: .text))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .countChanged(count):
            try container.encode(Kind.countChanged, forKey: .type)
            try container.encode(count, forKey: .count)
        case let .announcement(text):
            try container.encode(Kind.announcement, forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}

struct WorkoutEvent: Equatable, Codable, Sendable {
    let offset: TimeInterval
    let kind: WorkoutEventKind
}

struct WorkoutResult: Equatable, Sendable {
    let duration: TimeInterval
    let count: Int
    let endReason: WorkoutEndReason
    let videoURL: URL?
}

struct OverlaySegment: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let remainingSeconds: Int?
    let count: Int?

    var label: String {
        var parts: [String] = []
        if let remainingSeconds {
            parts.append("剩余 \(remainingSeconds.clockText)")
        }
        if let count {
            parts.append("\(count) 次")
        }
        return parts.joined(separator: "   ·   ")
    }
}

enum OverlayTimelineBuilder {
    static func build(
        actualDuration: TimeInterval,
        configuredDuration: TimeInterval,
        timerEnabled: Bool,
        counterEnabled: Bool,
        events: [WorkoutEvent]
    ) -> [OverlaySegment] {
        guard actualDuration > 0, timerEnabled || counterEnabled else { return [] }

        var boundaries: [TimeInterval] = [0, actualDuration]
        var wholeSecond = 1.0
        while wholeSecond < actualDuration {
            boundaries.append(wholeSecond)
            wholeSecond += 1
        }
        boundaries.append(contentsOf: events.compactMap { event in
            guard case .countChanged = event.kind else { return nil }
            return min(max(event.offset, 0), actualDuration)
        })

        let sorted = boundaries
            .sorted()
            .reduce(into: [TimeInterval]()) { result, value in
                if let last = result.last, abs(last - value) < 0.001 { return }
                result.append(value)
            }

        return zip(sorted, sorted.dropFirst()).compactMap { start, end in
            guard end - start > 0.001 else { return nil }
            let count = counterEnabled ? countValue(at: start, events: events) : nil
            let remaining: Int? = timerEnabled
                ? max(0, Int(ceil(configuredDuration - start)))
                : nil
            return OverlaySegment(
                start: start,
                end: end,
                remainingSeconds: remaining,
                count: count
            )
        }
    }

    private static func countValue(at offset: TimeInterval, events: [WorkoutEvent]) -> Int {
        events.reduce(0) { value, event in
            guard event.offset <= offset, case let .countChanged(count) = event.kind else {
                return value
            }
            return count
        }
    }
}
