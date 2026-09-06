import SwiftUI

struct RootFlowState: Equatable {
    static let splashDurationNanoseconds: UInt64 = 1_000_000_000

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
                BrandSplashView()
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
            flow.dismissSplash()
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

private struct BrandSplashView: View {
    var body: some View {
        ZStack {
            splashBackground

            Image("SplashBrand")
                .resizable()
                .scaledToFit()
                .frame(width: 317, height: 268)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("天天打卡，中小学生体测训练记录")
    }

    private var splashBackground: some View {
        ZStack {
            Image("SplashBackground")
                .resizable(resizingMode: .stretch)

            Image("SplashGlow")
                .resizable()
                .frame(width: 430, height: 430)
                .offset(x: 175, y: -245)
        }
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
