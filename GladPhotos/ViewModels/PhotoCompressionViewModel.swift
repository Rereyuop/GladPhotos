import Foundation
import Observation
import Photos

struct CreatedCompressedPhoto {
    let item: PhotoAssetItem
    let originalFileSize: Int64
    let compressedFileSize: Int64
}

@Observable
@MainActor
final class PhotoCompressionViewModel {
    private(set) var isCompressing = false
    private(set) var successMessage: String?
    var errorMessage: String?

    private var displayedAssetIdentifier: String
    private var generation = UUID()

    init(assetIdentifier: String) {
        displayedAssetIdentifier = assetIdentifier
    }

    func display(assetIdentifier: String) {
        guard displayedAssetIdentifier != assetIdentifier else { return }
        displayedAssetIdentifier = assetIdentifier
        generation = UUID()
        isCompressing = false
        successMessage = nil
        errorMessage = nil
    }

    func compress(
        asset: PHAsset,
        operation: @escaping (PHAsset) async throws -> CreatedCompressedPhoto,
        onCreated: @escaping (PhotoAssetItem) -> Void
    ) {
        guard !isCompressing else { return }

        let taskGeneration = generation
        let assetIdentifier = asset.localIdentifier
        isCompressing = true
        successMessage = nil
        errorMessage = nil

        Task {
            do {
                let result = try await operation(asset)
                guard isCurrent(taskGeneration, assetIdentifier: assetIdentifier) else { return }

                isCompressing = false
                onCreated(result.item)
                display(assetIdentifier: result.item.localIdentifier)
                let savings = Self.savingsPercent(
                    original: result.originalFileSize,
                    compressed: result.compressedFileSize
                )
                successMessage = "压缩完成 \(Self.fileSize(result.originalFileSize)) → \(Self.fileSize(result.compressedFileSize))，节省 \(savings)%"

                let successGeneration = generation
                try? await Task.sleep(for: .seconds(2))
                guard generation == successGeneration else { return }
                successMessage = nil
            } catch {
                guard isCurrent(taskGeneration, assetIdentifier: assetIdentifier) else { return }
                isCompressing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    static func savingsPercent(original: Int64, compressed: Int64) -> Int {
        guard original > 0 else { return 0 }
        return max(0, Int(((Double(original - compressed) / Double(original)) * 100).rounded()))
    }

    private func isCurrent(_ taskGeneration: UUID, assetIdentifier: String) -> Bool {
        generation == taskGeneration && displayedAssetIdentifier == assetIdentifier
    }

    private static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
