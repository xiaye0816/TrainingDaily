import AVKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject private var history = WorkoutHistoryStore.shared

    var body: some View {
        Group {
            if history.records.isEmpty {
                ContentUnavailableView(
                    "还没有训练记录",
                    systemImage: "figure.run",
                    description: Text("完成一次训练后，成绩和视频会出现在这里。")
                )
            } else {
                List {
                    ForEach(history.records) { record in
                        NavigationLink {
                            HistoryDetailView(recordID: record.id)
                        } label: {
                            recordRow(record)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            history.delete(history.records[index].id)
                        }
                    }
                }
            }
        }
        .navigationTitle("训练记录")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { history.removeExpiredVideos(now: Date()) }
    }

    private func recordRow(_ record: WorkoutRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(record.exercise.title, systemImage: record.exercise.icon)
                    .font(.headline)
                Spacer()
                videoStateLabel(record.videoState)
            }
            HStack(spacing: 18) {
                Label(Int(record.duration).clockText, systemImage: "timer")
                Label("\(record.count) 次", systemImage: "number")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }

    private func videoStateLabel(_ state: WorkoutVideoState) -> some View {
        let value: (String, String, Color) = switch state {
        case .processing: ("处理中", "clock", .orange)
        case .ready: ("可播放", "play.circle.fill", .workoutGreen)
        case .failed: ("失败", "exclamationmark.circle", .red)
        case .expired: ("仅记录", "doc.text", .secondary)
        }
        return Label(value.0, systemImage: value.1)
            .font(.caption.weight(.semibold))
            .foregroundStyle(value.2)
    }
}

private struct HistoryDetailView: View {
    @ObservedObject private var history = WorkoutHistoryStore.shared
    let recordID: UUID
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var saveMessage: String?

    private var record: WorkoutRecord? {
        history.records.first { $0.id == recordID }
    }

    var body: some View {
        ScrollView {
            if let record {
                VStack(spacing: 18) {
                    if let url = history.videoURL(for: record) {
                        WorkoutVideoPreview(url: url)
                            .aspectRatio(9 / 16, contentMode: .fit)
                            .frame(maxHeight: 480)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    } else {
                        statusCard(record)
                    }

                    HStack {
                        metric("时长", Int(record.duration).clockText)
                        Divider().frame(height: 46)
                        metric("次数", "\(record.count)")
                    }
                    .padding()
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    if let url = history.videoURL(for: record) {
                        Button {
                            guard !isSaving else { return }
                            isSaving = true
                            saveError = nil
                            Task {
                                do {
                                    try await PhotoLibrarySaver.saveVideo(at: url)
                                    history.markSavedToPhotos(record.id)
                                    saveMessage = "已保存到相册，可再次保存"
                                    isSaving = false
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    saveMessage = nil
                                } catch {
                                    isSaving = false
                                    saveError = error.localizedDescription
                                }
                            }
                        } label: {
                            if isSaving {
                                HStack {
                                    ProgressView().tint(.white)
                                    Text("正在保存")
                                }
                            } else {
                                Label(record.savedToPhotos ? "再次保存到相册" : "保存到相册", systemImage: "square.and.arrow.down")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isSaving)
                    }

                    if let saveMessage {
                        Label(saveMessage, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.workoutGreen)
                    }

                    if record.videoState == .failed, record.sourceVideoFilename != nil {
                        Button("重新处理视频") { history.retry(record.id) }
                            .buttonStyle(.borderedProminent)
                    }

                    if let saveError {
                        Text(saveError).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(18)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(record?.exercise.title ?? "训练记录")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statusCard(_ record: WorkoutRecord) -> some View {
        VStack(spacing: 12) {
            if record.videoState == .processing { ProgressView() }
            Image(systemName: record.videoState == .failed ? "exclamationmark.triangle" : "video.slash")
                .font(.largeTitle)
            Text(record.errorMessage ?? (record.videoState == .processing ? "视频处理中" : "视频已过期"))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}
