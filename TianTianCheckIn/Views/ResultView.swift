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
                            if session.photoSave.state.isSaving {
                                HStack {
                                    ProgressView().tint(.white)
                                    Text("正在保存")
                                }
                            } else {
                                Label(session.isSaved ? "再次保存到相册" : "保存到相册", systemImage: "square.and.arrow.down")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(session.photoSave.state.isSaving)
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
        .overlay(alignment: .top) {
            PhotoSaveToast(coordinator: session.photoSave)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .zIndex(10)
        }
    }

    @ViewBuilder
    private var videoPreview: some View {
        if let url = session.result?.videoURL {
            WorkoutVideoPreview(
                url: url,
                initialPosterData: session.result?.previewImageData
            )
                .aspectRatio(9 / 16, contentMode: .fit)
                .frame(maxHeight: 460)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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

enum VideoPosterGenerator {
    static func jpegData(for url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let image = try await generator.image(at: .zero).image
            return UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
        } catch {
            return nil
        }
    }
}

@MainActor
private final class WorkoutVideoPreviewModel: ObservableObject {
    let player: AVPlayer
    @Published var poster: UIImage?
    @Published var isShowingPoster = true
    private let url: URL
    private var timeObserver: Any?
    private var hasPrepared = false

    init(url: URL, initialPosterData: Data?) {
        self.url = url
        player = AVPlayer(url: url)
        poster = initialPosterData.flatMap(UIImage.init(data:))
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func prepare() {
        guard !hasPrepared else { return }
        hasPrepared = true
        AppAudioSession.activateVideoPlayback()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60),
            queue: .main
        ) { [weak self] time in
            guard time.seconds > 0.02 else { return }
            Task { @MainActor [weak self] in
                self?.isShowingPoster = false
            }
        }
        if poster == nil {
            Task { [weak self] in
                guard let self,
                      let data = await VideoPosterGenerator.jpegData(for: self.url),
                      let image = UIImage(data: data) else { return }
                self.poster = image
            }
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }
}

struct WorkoutVideoPreview: View {
    @StateObject private var model: WorkoutVideoPreviewModel

    init(url: URL, initialPosterData: Data? = nil) {
        _model = StateObject(
            wrappedValue: WorkoutVideoPreviewModel(
                url: url,
                initialPosterData: initialPosterData
            )
        )
    }

    var body: some View {
        ZStack {
            VideoPlayer(player: model.player)
            if model.isShowingPoster {
                Group {
                    if let poster = model.poster {
                        Image(uiImage: poster)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.workoutInk
                            .overlay {
                                ProgressView().tint(.white)
                            }
                    }
                }
                .clipped()
                Button {
                    model.play()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(.white, .black.opacity(0.48))
                        .shadow(radius: 5)
                }
                .accessibilityLabel("播放视频")
            }
        }
        .onAppear { model.prepare() }
        .onDisappear { model.pause() }
    }
}
