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

struct PhotoSaveToast: View {
    @ObservedObject var coordinator: PhotoSaveCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if coordinator.state.isVisible {
                HStack(spacing: 13) {
                    statusIcon
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if canOpenSettings {
                        Button("去设置") { coordinator.openSettings() }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .tint(Color.workoutGreen)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(borderColor.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.15), radius: 18, y: 7)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeOut(duration: 0.2), value: coordinator.state)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                coordinator.applicationBecameActive()
            } else {
                coordinator.applicationBecameInactive()
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch coordinator.state {
        case .saving:
            ProgressView()
                .tint(Color.workoutGreen)
        case .saved:
            Image(systemName: "checkmark")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.workoutGreen, in: Circle())
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.red, in: Circle())
        case .idle:
            EmptyView()
        }
    }

    private var title: String {
        switch coordinator.state {
        case .idle: ""
        case .saving: "正在保存到相册"
        case .saved: "已保存到相册"
        case .failed: "保存失败"
        }
    }

    private var subtitle: String? {
        switch coordinator.state {
        case .saved:
            "刚打开相册时，可能需要几秒刷新。"
        case let .failed(message, _):
            message
        default:
            nil
        }
    }

    private var canOpenSettings: Bool {
        if case let .failed(_, canOpenSettings) = coordinator.state { return canOpenSettings }
        return false
    }

    private var borderColor: Color {
        if case .failed = coordinator.state { return .red }
        return .workoutGreen
    }
}
