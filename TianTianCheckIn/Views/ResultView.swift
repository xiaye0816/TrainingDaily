import AVKit
import SwiftUI

struct ResultView: View {
    @EnvironmentObject private var session: WorkoutSessionController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    videoPreview
                    if session.isVideoProcessing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("视频正在快速处理中，可以先查看成绩")
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.workoutGreen.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    summary

                    if let message = session.errorMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if session.result?.videoURL != nil {
                        Button {
                            session.saveResult()
                        } label: {
                            if session.isSavingToPhotos {
                                HStack {
                                    ProgressView().tint(.white)
                                    Text("正在保存")
                                }
                            } else {
                                Label(session.isSaved ? "再次保存到相册" : "保存到相册", systemImage: "square.and.arrow.down")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(session.isSavingToPhotos)
                    }

                    if let saveMessage = session.saveMessage {
                        Label(saveMessage, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.workoutGreen)
                    }

                    Button {
                        session.retry()
                    } label: {
                        Label("重新录制", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(session.isSaved ? "完成，返回设置" : "放弃并返回设置") {
                        session.returnHome()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("本次完成")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var videoPreview: some View {
        if let url = session.result?.videoURL {
            VideoPlayer(player: AVPlayer(url: url))
                .aspectRatio(9 / 16, contentMode: .fit)
                .frame(maxHeight: 460)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onAppear { AppAudioSession.activateVideoPlayback() }
        } else if session.isVideoProcessing {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.workoutInk)
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("相机已关闭\n正在生成视频")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
            }
            .frame(height: 220)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.workoutInk)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Color.workoutGreen)
            }
            .frame(height: 220)
        }
    }

    private var summary: some View {
        HStack(spacing: 0) {
            resultMetric(
                title: "时长",
                value: Int(session.result?.duration ?? 0).clockText
            )
            Divider().frame(height: 52)
            resultMetric(
                title: "次数",
                value: "\(session.result?.count ?? 0)"
            )
        }
        .padding(.vertical, 18)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func resultMetric(title: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}
