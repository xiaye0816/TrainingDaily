import Combine
import Foundation

@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: WorkoutConfig {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private let key = "workout.config.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(WorkoutConfig.self, from: data) {
            config = decoded.normalized
        } else {
            config = .default
        }
    }

    func reset() {
        config = .default
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config.normalized) else { return }
        defaults.set(data, forKey: key)
    }
}
