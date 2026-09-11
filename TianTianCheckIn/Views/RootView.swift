import SwiftUI
import UIKit

struct RootFlowState: Equatable {
    static let splashDurationNanoseconds: UInt64 = 500_000_000

    private(set) var isShowingSplash = true

    mutating func dismissSplash() {
        isShowingSplash = false
    }
}

struct RootView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var session: WorkoutSessionController
    @State private var flow = RootFlowState()

    var body: some View {
        ZStack {
            mainContent

            if flow.isShowingSplash {
                NativeLaunchSplashView()
                    .ignoresSafeArea()
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                    .zIndex(1)
            }
        }
        .preferredColorScheme(.light)
        .task {
            guard flow.isShowingSplash else { return }
            await Task.yield()
            do {
                try await Task.sleep(nanoseconds: RootFlowState.splashDurationNanoseconds)
            } catch {
                return
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                flow.dismissSplash()
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch session.phase {
        case .idle:
            SetupView(config: $configStore.config) {
                session.prepare(config: configStore.config)
            }
        case .result:
            ResultView()
        case .failed:
            FailureView()
        default:
            WorkoutView()
        }
    }
}

private struct NativeLaunchSplashView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        UIStoryboard(name: "LaunchScreenStable", bundle: .main).instantiateInitialViewController()
            ?? fallbackController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private func fallbackController() -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = UIColor(red: 0.98, green: 0.99, blue: 0.96, alpha: 1)
        return controller
    }
}

private struct FailureView: View {
    @EnvironmentObject private var session: WorkoutSessionController

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("这次没有完成")
                .font(.title.bold())
            Text(session.errorMessage ?? "发生了未知错误，请重试。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button("重新准备") {
                session.retry()
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("返回设置") {
                session.returnHome()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(Color.workoutGreen.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
