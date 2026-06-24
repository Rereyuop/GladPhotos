import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

struct PhotoCompressionResult: Sendable {
    let localIdentifier: String
    let originalFileSize: Int64
    let compressedFileSize: Int64
}

enum PhotoCompressionError: LocalizedError {
    case unsupportedFormat
    case originalResourceUnavailable
    case imageSourceUnavailable
    case imageDestinationUnavailable
    case compressionFailed
    case createdAssetUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "仅支持普通 JPEG、HEIC 和 PNG 照片"
        case .originalResourceUnavailable:
            "无法读取照片的原始资源"
        case .imageSourceUnavailable:
            "无法解析原始图片"
        case .imageDestinationUnavailable:
            "无法创建压缩图片"
        case .compressionFailed:
            "图片压缩失败"
        case .createdAssetUnavailable:
            "图库没有返回新照片标识"
        }
    }
}

final class PhotoCompressionService: @unchecked Sendable {
    private let resourceManager: PHAssetResourceManager
    private let photoLibrary: PHPhotoLibrary
    private let fileManager: FileManager

    init(
        resourceManager: PHAssetResourceManager = .default(),
        photoLibrary: PHPhotoLibrary = .shared(),
        fileManager: FileManager = .default
    ) {
        self.resourceManager = resourceManager
        self.photoLibrary = photoLibrary
        self.fileManager = fileManager
    }

    func isSupported(_ asset: PHAsset) -> Bool {
        supportedPhotoResource(for: asset) != nil
    }

    func compress(_ asset: PHAsset) async throws -> PhotoCompressionResult {
        guard let resource = supportedPhotoResource(for: asset) else {
            throw PhotoCompressionError.unsupportedFormat
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("GladPhotos-Compression-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let sourceExtension = URL(fileURLWithPath: resource.originalFilename).pathExtension
        let sourceURL = directory.appendingPathComponent("original").appendingPathExtension(sourceExtension)
        let baseName = URL(fileURLWithPath: resource.originalFilename)
            .deletingPathExtension().lastPathComponent
        let outputURL = directory.appendingPathComponent("\(baseName)_compressed.jpg")

        try await export(resource, to: sourceURL)
        let originalSize = try fileSize(at: sourceURL)
        try await Self.encodeJPEG(from: sourceURL, to: outputURL)
        let compressedSize = try fileSize(at: outputURL)
        let identifier = try await createAsset(
            from: outputURL,
            filename: outputURL.lastPathComponent,
            creationDate: asset.creationDate.map { $0.addingTimeInterval(1) },
            location: asset.location
        )

        return PhotoCompressionResult(
            localIdentifier: identifier,
            originalFileSize: originalSize,
            compressedFileSize: compressedSize
        )
    }

    private func supportedPhotoResource(for asset: PHAsset) -> PHAssetResource? {
        guard asset.mediaType == .image,
              !asset.mediaSubtypes.contains(.photoLive)
        else {
            return nil
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let rawExtensions: Set<String> = [
            "3fr", "arw", "cr2", "cr3", "dng", "erf", "kdc", "mos", "mrw",
            "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "srw", "x3f"
        ]
        guard !resources.contains(where: {
            rawExtensions.contains(
                URL(fileURLWithPath: $0.originalFilename).pathExtension.lowercased()
            )
        }) else {
            return nil
        }

        let resource = resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
        guard let resource,
              let type = UTType(resource.uniformTypeIdentifier),
              type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .png)
        else {
            return nil
        }
        return resource
    }

    private func export(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            resourceManager.writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func encodeJPEG(from sourceURL: URL, to outputURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
                throw PhotoCompressionError.imageSourceUnavailable
            }
            guard CGImageSourceGetCount(source) > 0 else {
                throw PhotoCompressionError.imageSourceUnavailable
            }
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                throw PhotoCompressionError.imageDestinationUnavailable
            }

            var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]) ?? [:]
            properties[kCGImageDestinationLossyCompressionQuality] = 0.82
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw PhotoCompressionError.compressionFailed
            }
        }.value
    }

    private func createAsset(
        from url: URL,
        filename: String,
        creationDate: Date?,
        location: CLLocation?
    ) async throws -> String {
        var placeholderIdentifier: String?

        try await photoLibrary.performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = creationDate
            request.location = location

            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            options.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: url, options: options)
            placeholderIdentifier = request.placeholderForCreatedAsset?.localIdentifier
        }

        guard let placeholderIdentifier else {
            throw PhotoCompressionError.createdAssetUnavailable
        }
        return placeholderIdentifier
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}
