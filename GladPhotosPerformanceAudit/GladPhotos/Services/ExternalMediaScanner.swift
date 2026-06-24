import Foundation
import ImageIO

actor ExternalMediaScanner {
    private var cache: [URL: [ExternalMediaItem]] = [:]

    enum ScanError: LocalizedError {
        case folderUnavailable

        var errorDescription: String? {
            switch self {
            case .folderUnavailable:
                return "文件夹不存在或没有读取权限"
            }
        }
    }

    func scan(folderURL: URL, recursively: Bool = true) async throws -> [ExternalMediaItem] {
        let scanStart = ContinuousClock.now
        let folderKey = folderURL.standardizedFileURL
        let previousItems = Dictionary(
            uniqueKeysWithValues: (cache[folderKey] ?? []).map { ($0.url, $0) }
        )
        // Design reference: netdcy/FlowVision FileSystem.swift @ d8a725c.
        // Keep flat and recursive enumeration as separate fast paths, and check
        // cancellation while consuming directory results. Implementation is native
        // to GladPhotos and intentionally excludes FlowVision's global state/UI.
        let enumerationTask = Task.detached(priority: .userInitiated) {
            try Self.enumerateMedia(in: folderURL, recursively: recursively)
        }
        let candidates = try await withTaskCancellationHandler {
            try await enumerationTask.value
        } onCancel: {
            enumerationTask.cancel()
        }
        let pairs = Self.livePhotoPairs(in: candidates)
        var items: [ExternalMediaItem] = []

        for candidate in candidates {
            try Task.checkCancellation()
            if pairs.consumedVideoURLs.contains(candidate.url) {
                continue
            }

            let pairedVideo = pairs.videoByImageURL[candidate.url]
            let mediaType = pairedVideo == nil ? candidate.mediaType : .livePhoto
            let fileSize = combinedFileSize(candidate, pairedVideo)
            let duration: TimeInterval?
            let pixelSize: (width: Int?, height: Int?)
            if let previous = previousItems[candidate.url],
               previous.mediaType == mediaType,
               previous.pairedVideoURL == pairedVideo?.url,
               previous.fileSize == fileSize,
               previous.creationDate == candidate.creationDate,
               previous.modificationDate == candidate.modificationDate {
                duration = previous.duration
                pixelSize = (previous.pixelWidth, previous.pixelHeight)
            } else {
                // Duration parsing is deliberately deferred to video playback/detail.
                // Serial AVURLAsset metadata loads made large folders appear stuck.
                duration = nil
                pixelSize = mediaType == .video ? (nil, nil) : Self.imagePixelSize(at: candidate.url)
            }

            items.append(
                ExternalMediaItem(
                    url: candidate.url,
                    pairedVideoURL: pairedVideo?.url,
                    mediaType: mediaType,
                    fileSize: fileSize,
                    creationDate: candidate.creationDate,
                    modificationDate: candidate.modificationDate,
                    duration: duration,
                    pixelWidth: pixelSize.width,
                    pixelHeight: pixelSize.height
                )
            )
        }

        let sortedItems = items.sorted {
            let lhsDate = $0.modificationDate ?? .distantPast
            let rhsDate = $1.modificationDate ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
        }
        cache[folderKey] = sortedItems
        PerformanceLogger.log(
            "scan",
            duration: scanStart.duration(to: .now),
            details: "items=\(sortedItems.count)"
        )
        return sortedItems
    }

    func cachedItems(for folderURL: URL) -> [ExternalMediaItem]? {
        cache[folderURL.standardizedFileURL]
    }

    func removeCache(for folderURL: URL) {
        cache.removeValue(forKey: folderURL.standardizedFileURL)
    }

    func removeCachedItems(at urls: Set<URL>, from folderURL: URL) {
        let key = folderURL.standardizedFileURL
        cache[key]?.removeAll { item in
            !urls.isDisjoint(with: item.sourceURLs)
        }
    }

    nonisolated private static func livePhotoPairs(
        in candidates: [ScanCandidate]
    ) -> (videoByImageURL: [URL: ScanCandidate], consumedVideoURLs: Set<URL>) {
        let groups = Dictionary(grouping: candidates) { candidate in
            PairingKey(
                directory: candidate.url.deletingLastPathComponent().standardizedFileURL.path,
                basename: candidate.url.deletingPathExtension().lastPathComponent.lowercased()
            )
        }
        var videoByImageURL: [URL: ScanCandidate] = [:]
        var consumedVideoURLs = Set<URL>()

        for group in groups.values {
            guard let video = group.first(where: {
                $0.mediaType == .video && $0.url.pathExtension.lowercased() == "mov"
            }), let image = group
                .filter({ $0.mediaType == .image })
                .sorted(by: { imagePreference($0.url) < imagePreference($1.url) })
                .first
            else {
                continue
            }
            videoByImageURL[image.url] = video
            consumedVideoURLs.insert(video.url)
        }
        return (videoByImageURL, consumedVideoURLs)
    }

    nonisolated private static func imagePreference(_ url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "heic": 0
        case "heif": 1
        case "jpg", "jpeg": 2
        default: 3
        }
    }

    nonisolated private func combinedFileSize(
        _ candidate: ScanCandidate,
        _ pairedVideo: ScanCandidate?
    ) -> Int64? {
        switch (candidate.fileSize, pairedVideo?.fileSize) {
        case let (imageSize?, videoSize?): imageSize + videoSize
        case let (imageSize?, nil): imageSize
        case let (nil, videoSize?): videoSize
        case (nil, nil): nil
        }
    }

    nonisolated private static func enumerateMedia(
        in folderURL: URL,
        recursively: Bool
    ) throws -> [ScanCandidate] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: folderURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ScanError.folderUnavailable
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]

        var candidates: [ScanCandidate] = []
        if recursively {
            guard let enumerator = FileManager.default.enumerator(
                at: folderURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                throw ScanError.folderUnavailable
            }
            var visitedCount = 0
            for case let fileURL as URL in enumerator {
                visitedCount += 1
                if visitedCount.isMultiple(of: 64) { try Task.checkCancellation() }
                appendCandidate(fileURL, keys: keys, to: &candidates)
            }
        } else {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            for (index, fileURL) in urls.enumerated() {
                if index.isMultiple(of: 64) { try Task.checkCancellation() }
                appendCandidate(fileURL, keys: keys, to: &candidates)
            }
        }
        return candidates
    }

    nonisolated private static func appendCandidate(
        _ url: URL,
        keys: Set<URLResourceKey>,
        to candidates: inout [ScanCandidate]
    ) {
        // Extension filtering happens before any metadata syscall. This is a major
        // win in folders containing many unrelated files.
        guard let mediaType = mediaType(for: url),
              let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else { return }

        candidates.append(
            ScanCandidate(
                url: url,
                mediaType: mediaType,
                fileSize: values.fileSize.map(Int64.init),
                creationDate: values.creationDate,
                modificationDate: values.contentModificationDate
            )
        )
    }

    nonisolated private static func imagePixelSize(at url: URL) -> (Int?, Int?) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return (nil, nil) }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return (nil, nil) }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    nonisolated private static func mediaType(for url: URL) -> ExternalMediaType? {
        let supportedImageExtensions = Set(["heic", "heif", "jpg", "jpeg", "png"])
        let supportedVideoExtensions = Set(["mov", "mp4", "m4v"])
        let fileExtension = url.pathExtension.lowercased()

        if supportedImageExtensions.contains(fileExtension) {
            return .image
        }

        if supportedVideoExtensions.contains(fileExtension) {
            return .video
        }

        return nil
    }

}

private struct ScanCandidate: Sendable {
    let url: URL
    let mediaType: ExternalMediaType
    let fileSize: Int64?
    let creationDate: Date?
    let modificationDate: Date?
}

nonisolated private struct PairingKey: Hashable {
    let directory: String
    let basename: String
}
