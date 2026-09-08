import SwiftUI

struct WorkoutView: View {
    @EnvironmentObject private var session: WorkoutSessionController

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                previewBackground
                Color.black.opacity(session.currentConfig.recordingEnabled ? 0.08 : 0.72)

                switch session.phase {
                case .preparingCamera:
                    statusView(title: "正在准备摄像头", subtitle: "首次使用时请允许所需权限")
                case .framing:
                    framingControls(isLandscape: proxy.size.width > proxy.size.height)
                case let .countdown(number):
                    countdownView(number)
                case .active:
                    activeControls(isLandscape: proxy.size.width > proxy.size.height)
                case .processing:
                    statusView(title: "正在生成成片", subtitle: "写入时间和次数，请不要退出")
                default:
                    EmptyView()
                }
            }
            .ignoresSafeArea()
        }
        .background(.black)
        .statusBarHidden(session.phase == .active || session.phase == .countdown(1) || session.phase == .countdown(2) || session.phase == .countdown(3))
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            session.updateCameraOrientation(UIDevice.current.orientation)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            session.updateCameraOrientation(UIDevice.current.orientation)
        }
    }

    @ViewBuilder
    private var previewBackground: some View {
        if session.currentConfig.recordingEnabled {
            CameraPreview(session: session.cameraRecorder.session)
        } else {
            ZStack {
                Color.workoutInk
                Image(systemName: "figure.core.training")
                    .font(.system(size: 96, weight: .thin))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
    }

    private func framingControls(isLandscape: Bool) -> some View {
        VStack {
            HStack {
                Button {
                    session.cancelBeforeStart()
                } label: {
                    Label("返回", systemImage: "xmark")
                }
                .buttonStyle(GlassButtonStyle())

                Spacer()

                if session.currentConfig.recordingEnabled {
                    Button {
                        session.switchCamera()
                    } label: {
                        Label("切换镜头", systemImage: "camera.rotate")
                    }
                    .buttonStyle(GlassButtonStyle())
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            Spacer(minLength: 12)

            framingGuide(isLandscape: isLandscape)

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                Text(session.currentConfig.countingMode == .automatic
                     ? session.poseStatus.message
                     : session.currentConfig.exerciseType.framingInstruction)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(radius: 4)
                Button {
                    session.beginCountdown(orientation: UIDevice.current.orientation)
                } label: {
                    Label("准备好了", systemImage: "checkmark")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!session.canBeginCountdown)
                .opacity(session.canBeginCountdown ? 1 : 0.52)

                if session.currentConfig.countingMode == .automatic, !session.canBeginCountdown {
                    Button("改用手动计次") {
                        session.useManualCountingForCurrentSession()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                }
            }
            .padding(18)
            .background(.black.opacity(0.45))
        }
    }

    private func framingGuide(isLandscape: Bool) -> some View {
        let isJumpRope = session.currentConfig.exerciseType == .jumpRope
        let width: CGFloat = isJumpRope ? (isLandscape ? 125 : 190) : (isLandscape ? 300 : 310)
        let height: CGFloat = isJumpRope ? (isLandscape ? 190 : 310) : (isLandscape ? 145 : 160)

        return ZStack {
            RoundedRectangle(cornerRadius: isJumpRope ? 70 : 45, style: .continuous)
                .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
            Image(systemName: session.currentConfig.exerciseType.icon)
                .font(.system(size: min(width, height) * 0.5, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    private func countdownView(_ number: Int) -> some View {
        VStack(spacing: 14) {
            Text("准备")
                .font(.title2.weight(.medium))
            Text("\(number)")
                .font(.system(size: 150, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
        }
        .foregroundStyle(.white)
        .shadow(radius: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("准备，\(number)")
    }

    @ViewBuilder
    private func activeControls(isLandscape: Bool) -> some View {
        if isLandscape {
            HStack(spacing: 18) {
                VStack {
                    sessionHeader
                    Spacer()
                    secondaryControls
                }
                Spacer()
                if session.currentConfig.counterEnabled {
                    countButton
                        .frame(width: 190)
                }
            }
            .padding(20)
        } else {
            VStack(spacing: 18) {
                sessionHeader
                Spacer()
                if session.currentConfig.counterEnabled {
                    countButton
                        .frame(height: 154)
                }
                secondaryControls
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
        }
    }

    private var sessionHeader: some View {
        HStack(spacing: 12) {
            if session.currentConfig.recordingEnabled {
                Label("REC", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
            }
            if session.currentConfig.countingMode == .automatic {
                Label(
                    session.poseStatus == .tracking ? "识别中" : "识别暂停",
                    systemImage: session.poseStatus == .tracking ? "viewfinder" : "person.crop.circle.badge.exclamationmark"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(session.poseStatus == .tracking ? Color.workoutGreen : .orange)
            }
            if session.currentConfig.timerEnabled {
                metric(title: "剩余", value: session.displayTime)
            } else {
                metric(title: "已用", value: session.displayTime)
            }
            if session.currentConfig.counterEnabled {
                metric(title: "次数", value: "\(session.count)")
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .background(.black.opacity(0.62))
        .clipShape(Capsule())
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
        }
    }

    private var countButton: some View {
        Button {
            session.incrementCount()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 44, weight: .bold))
                Text(session.isAutomaticCountingActive ? "补计 +1" : "计一次")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.workoutGreen.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("增加一次，当前 \(session.count) 次")
    }

    private var secondaryControls: some View {
        HStack(spacing: 12) {
            if session.currentConfig.counterEnabled {
                Button {
                    session.undoCount()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(session.count == 0)
            }
            Button(role: .destructive) {
                session.finishManually()
            } label: {
                Label("结束", systemImage: "stop.fill")
            }
            .buttonStyle(GlassButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusView(title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.3)
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(28)
        .background(.black.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.65 : 1))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.black.opacity(0.55))
            .clipShape(Capsule())
    }
}
