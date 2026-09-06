import SwiftUI

struct SetupView: View {
    @Binding var config: WorkoutConfig
    let onBack: () -> Void
    let onStart: () -> Void

    private let durationOptions = [30, 60, 90, 120, 300]
    private let timeIntervals = [5, 10, 15, 30, 60]
    private let countIntervals = [1, 5, 10]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    timerCard
                    counterCard
                    recordingCard
                    Button(action: onStart) {
                        Label(config.recordingEnabled ? "进入取景" : "开始运动", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityHint("打开取景并准备开始本次运动")
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("训练设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Label("首页", systemImage: "chevron.left")
                    }
                    .accessibilityHint("返回天天打卡首页")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("恢复默认设置", role: .destructive) {
                            config = .default
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多设置")
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "stopwatch.fill")
                    .font(.title2)
                    .foregroundStyle(Color.workoutGreen)
                Text("本次训练")
                    .font(.title2.bold())
            }
            Text(config.durationSeconds.clockText)
                .font(.system(size: 66, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
            Text("每一秒，每一次，都看得见。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
    }

    private var timerCard: some View {
        SettingsCard(title: "计时", icon: "timer", isEnabled: $config.timerEnabled) {
            Picker("运动时长", selection: $config.durationSeconds) {
                ForEach(durationOptions, id: \.self) { seconds in
                    Text(seconds.clockText).tag(seconds)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $config.durationSeconds, in: 10...3_600, step: 5) {
                HStack {
                    Text("精确时长")
                    Spacer()
                    Text(config.durationSeconds.clockText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Toggle("时间播报", isOn: $config.timeAnnouncementEnabled)
            if config.timeAnnouncementEnabled {
                Picker("播报间隔", selection: $config.timeAnnouncementInterval) {
                    ForEach(timeIntervals, id: \.self) { seconds in
                        Text("\(seconds) 秒").tag(seconds)
                    }
                }
                Toggle("最后 5 秒逐秒播报", isOn: $config.finalCountdownEnabled)
            }
            Toggle("时间到自动结束", isOn: $config.autoStopAtTimerEnd)
        }
    }

    private var counterCard: some View {
        SettingsCard(title: "计次", icon: "plus.circle", isEnabled: $config.counterEnabled) {
            Toggle("计次播报", isOn: $config.countAnnouncementEnabled)
            if config.countAnnouncementEnabled {
                Picker("每几次播报", selection: $config.countAnnouncementInterval) {
                    ForEach(countIntervals, id: \.self) { interval in
                        Text("每 \(interval) 次").tag(interval)
                    }
                }
            }
            Text("运动中点击大按钮 +1，误触时可撤销。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingCard: some View {
        SettingsCard(title: "录像", icon: "video", isEnabled: $config.recordingEnabled) {
            Toggle("保留现场声音", isOn: $config.microphoneEnabled)
            Text("完成后会生成带时间与次数的成片，确认后再保存到系统相册。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isEnabled: Bool
    @ViewBuilder let content: Content

    init(
        title: String,
        icon: String,
        isEnabled: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        _isEnabled = isEnabled
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .accessibilityLabel("启用\(title)")
            }
            if isEnabled {
                Divider()
                VStack(spacing: 14) {
                    content
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(18)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }
}
