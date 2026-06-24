import AppKit
import Foundation

@MainActor
enum ExternalMediaDeletionService {
    enum DeletionError: LocalizedError {
        case incomplete

        var errorDescription: String? {
            "部分源文件未能移到废纸篓，请刷新后重试。"
        }
    }

    static func moveToTrash(_ item: ExternalMediaItem) async throws {
        let sourceURLs = item.sourceURLs

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.recycle(sourceURLs) { trashedURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if trashedURLs.count != sourceURLs.count {
                    continuation.resume(throwing: DeletionError.incomplete)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
