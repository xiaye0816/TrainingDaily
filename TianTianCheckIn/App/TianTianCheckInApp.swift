import SwiftUI

@main
struct TianTianCheckInApp: App {
    @StateObject private var configStore = ConfigStore()
    @StateObject private var sessionController = WorkoutSessionController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(configStore)
                .environmentObject(sessionController)
                .tint(.workoutGreen)
        }
    }
}

extension Color {
    static let workoutGreen = Color(red: 0.10, green: 0.72, blue: 0.38)
    static let workoutInk = Color(red: 0.06, green: 0.10, blue: 0.08)
}
