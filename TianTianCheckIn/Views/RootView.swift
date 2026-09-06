import SwiftUI

struct RootView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var session: WorkoutSessionController

    var body: some View {
        Group {
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
        .preferredColorScheme(.light)
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
