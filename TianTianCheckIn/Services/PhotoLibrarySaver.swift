import Combine
import Darwin
import Foundation
@preconcurrency import Photos
import UIKit

enum PhotoLibraryError: LocalizedError {
    case permissionDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "请在系统设置中允许“天天打卡”添加照片。"
        case .saveFailed: "视频未能保存到系统相册。"
        }
    }
}

struct PhotoLibrarySaveResult: Sendable {
    let localIdentifier: String?
}

enum PhotoSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed(message: String, canOpenSettings: Bool)

    var isSaving: Bool { self == .saving }
    var isVisible: Bool { self != .idle }
}

enum PhotoLibrarySaver {
    @MainActor
    static func saveVideo(at url: URL) async throws -> PhotoLibrarySaveResult {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.permissionDenied
        }

        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SaveWorkoutToPhotos")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        let stagingURL = makeCloneForFastImport(sourceURL: url)
        let importURL = stagingURL ?? url
        defer {
            if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
        }

        var localIdentifier: String?
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                if stagingURL != nil {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    options.originalFilename = url.lastPathComponent
                    request.addResource(with: .video, fileURL: importURL, options: options)
                    localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
                } else {
                    let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    localIdentifier = request?.placeholderForCreatedAsset?.localIdentifier
                }
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoLibraryError.saveFailed)
                }
            }
        }
        return PhotoLibrarySaveResult(localIdentifier: localIdentifier)
    }

    private static func makeCloneForFastImport(sourceURL: URL) -> URL? {
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-import-\(UUID().uuidString)")
            .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)
        guard copyfile(sourceURL.path, stagingURL.path, nil, flags) == 0 else {
            try? FileManager.default.removeItem(at: stagingURL)
            return nil
        }
        return stagingURL
    }
}

@MainActor
final class PhotoSaveCoordinator: ObservableObject {
    @Published private(set) var state: PhotoSaveState = .idle

    private var dismissTask: Task<Void, Never>?

    func save(videoURL: URL, onSuccess: @escaping @MainActor () -> Void) {
        guard !state.isSaving else { return }
        dismissTask?.cancel()
        state = .saving
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: "正在保存到相册")

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await PhotoLibrarySaver.saveVideo(at: videoURL)
                onSuccess()
                state = .saved
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(notification: .announcement, argument: "已保存到相册")
                scheduleDismiss(after: 3)
            } catch PhotoLibraryError.permissionDenied {
                state = .failed(
                    message: PhotoLibraryError.permissionDenied.localizedDescription,
                    canOpenSettings: true
                )
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                scheduleDismiss(after: 6)
            } catch {
                state = .failed(message: error.localizedDescription, canOpenSettings: false)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                scheduleDismiss(after: 4)
            }
        }
    }

    func applicationBecameActive() {
        switch state {
        case .saved:
            scheduleDismiss(after: 3)
        case .failed:
            scheduleDismiss(after: 4)
        default:
            break
        }
    }

    func applicationBecameInactive() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        if !state.isSaving { state = .idle }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        guard UIApplication.shared.applicationState == .active else { return }
        let expectedState = state
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, state == expectedState else { return }
            state = .idle
        }
    }
}
