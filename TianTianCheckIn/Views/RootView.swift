import SwiftUI

enum IdleScreen: Equatable {
    case welcome
    case setup
}

struct RootFlowState: Equatable {
    private(set) var idleScreen: IdleScreen = .welcome

    mutating func showSetup() {
        idleScreen = .setup
    }

    mutating func showWelcome() {
        idleScreen = .welcome
    }
}

struct RootView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var session: WorkoutSessionController
    @State private var flow = RootFlowState()

    var body: some View {
        Group {
            switch session.phase {
            case .idle:
                switch flow.idleScreen {
                case .welcome:
                    WelcomeView {
                        flow.showSetup()
                    }
                case .setup:
                    SetupView(
                        config: $configStore.config,
                        onBack: { flow.showWelcome() },
                        onStart: { session.prepare(config: configStore.config) }
                    )
                }
            case .result:
                ResultView {
                    session.returnHome()
                    flow.showWelcome()
                }
            case .failed:
                FailureView()
            default:
                WorkoutView()
            }
        }
        .preferredColorScheme(.light)
    }
}

private struct WelcomeView: View {
    let onStart: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                welcomeBackground

                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 52)
                        brand
                        Spacer(minLength: 38)
                        featureCard
                        Spacer(minLength: 42)
                        startButton
                        privacyNote
                    }
                    .frame(minHeight: max(proxy.size.height, 640))
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var welcomeBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.92, green: 1.00, blue: 0.95),
                    Color(red: 0.98, green: 0.99, blue: 0.96),
                    .white
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.workoutGreen.opacity(0.09))
                .frame(width: 360, height: 360)
                .offset(x: 150, y: -250)

            Circle()
                .fill(Color.yellow.opacity(0.10))
                .frame(width: 260, height: 260)
                .offset(x: -150, y: 320)
        }
        .ignoresSafeArea()
    }

    private var brand: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.workoutGreen, Color(red: 0.04, green: 0.58, blue: 0.30)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.workoutGreen.opacity(0.28), radius: 24, y: 12)

                Image(systemName: "figure.run")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 112, height: 112)

            VStack(spacing: 8) {
                Text("天天打卡")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.workoutInk)

                Text("中小学生体测训练记录")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("每一秒，每一次，都看得见。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary.opacity(0.86))
                    .padding(.top, 2)
            }
            .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private var featureCard: some View {
        HStack(spacing: 8) {
            WelcomeFeature(icon: "timer", title: "计时播报")
            WelcomeFeature(icon: "plus.circle.fill", title: "轻触计次")
            WelcomeFeature(icon: "video.fill", title: "录像留档")
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 10)
        .background(.white.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }

    private var startButton: some View {
        Button(action: onStart) {
            HStack {
                Text("开始一次训练")
                Spacer()
                Image(systemName: "arrow.right")
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityHint("进入计时、计次和录像设置")
    }

    private var privacyNote: some View {
        Label("无需账号，训练数据仅保存在本机", systemImage: "lock.shield.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 16)
    }
}

private struct WelcomeFeature: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.workoutGreen)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.workoutInk.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
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
