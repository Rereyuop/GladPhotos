import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

actor ExternalMediaScanner {
    private var cache: [URL: [ExternalMediaItem]] = [:]
    private var lastIndexBenchmark: [UUID: ExternalMediaIndexBenchmark] = [:]

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
        try await scan(folderID: nil, folderURL: folderURL, recursively: recursively)
    }

    func scan(folderID: UUID, folderURL: URL, recursively: Bool = true) async throws -> [ExternalMediaItem] {
        try await scan(folderID: Optional(folderID), folderURL: folderURL, recursively: recursively)
    }

    func indexedItems(folderID: UUID, folderURL: URL) async -> ExternalMediaIndexSnapshot? {
        let restoreStart = ContinuousClock.now
        let indexStore = ExternalMediaIndexStore(folderID: folderID)
        do {
            guard let snapshot = try await indexStore.loadSnapshot() else { return nil }
            cache[folderURL.standardizedFileURL] = snapshot.items
            lastIndexBenchmark[folderID] = ExternalMediaIndexBenchmark(
                indexRestoreDuration: restoreStart.duration(to: .now),
                databaseSizeBytes: snapshot.databaseSizeBytes
            )
            PerformanceLogger.log(
                "external-index-restore",
                duration: restoreStart.duration(to: .now),
                details: "items=\(snapshot.items.count) state=\(snapshot.state) dbSize=\(snapshot.databaseSizeBytes ?? 0)"
            )
            return snapshot
        } catch {
            try? await indexStore.reset()
            PerformanceLogger.log(
                "external-index-restore",
                duration: restoreStart.duration(to: .now),
                details: "reset reason=\(error.localizedDescription)"
            )
            return nil
        }
    }

    func benchmark(for folderID: UUID) -> ExternalMediaIndexBenchmark? {
        lastIndexBenchmark[folderID]
    }

    private func scan(
        folderID: UUID?,
        folderURL: URL,
        recursively: Bool = true
    ) async throws -> [ExternalMediaItem] {
        let scanStart = ContinuousClock.now
        let folderKey = folderURL.standardizedFileURL
        let previousList = cache[folderKey] ?? []
        let previousByID = Dictionary(uniqueKeysWithValues: previousList.map { ($0.stableMediaID, $0) })
        let previousByPath = Dictionary(uniqueKeysWithValues: previousList.map { ($0.normalizedPath, $0) })
        // Design reference: netdcy/FlowVision FileSystem.swift @ d8a725c.
        // Keep flat and recursive enumeration as separate fast paths, and check
        // cancellation while consuming directory results. Implementation is native
        // to GladPhotos and intentionally excludes FlowVision's global state/UI.
        let enumerationTask = Task.detached(priority: .userInitiated) {
            try await Self.enumerateMedia(in: folderURL, recursively: recursively)
        }
        let candidates = try await withTaskCancellationHandler {
            try await enumerationTask.value
        } onCancel: {
            enumerationTask.cancel()
        }
        let validationDuration = scanStart.duration(to: .now)
        let resourceIdentifierCounts = Dictionary(
            grouping: candidates.compactMap(\.fileResourceIdentifier),
            by: { $0 }
        ).mapValues(\.count)
        let pairs = Self.livePhotoPairs(in: candidates)
        var items: [ExternalMediaItem] = []

        for candidate in candidates {
            try Task.checkCancellation()
            if pairs.consumedVideoURLs.contains(candidate.url) {
                continue
            }

            let pairedVideo = pairs.videoByImageURL[candidate.url]
            let mediaType = pairedVideo == nil ? candidate.mediaType : .livePhoto
            let stableMediaID = Self.stableMediaID(
                for: candidate,
                resourceIdentifierCounts: resourceIdentifierCounts
            )
            let pairedVideoStableID = pairedVideo.map {
                Self.stableMediaID(for: $0, resourceIdentifierCounts: resourceIdentifierCounts)
            }
            let fileSize = combinedFileSize(candidate, pairedVideo)
            let duration: TimeInterval?
            let imageMetadata: ImageMetadata
            let previous = previousByID[stableMediaID] ?? previousByPath[candidate.normalizedPath]
            if let previous,
               previous.mediaType == mediaType,
               previous.pairedVideoURL == pairedVideo?.url,
               previous.fileSize == fileSize,
               previous.fileResourceIdentifier == candidate.fileResourceIdentifier,
               previous.modificationDate == candidate.modificationDate {
                duration = previous.duration
                imageMetadata = ImageMetadata(
                    pixelWidth: previous.pixelWidth,
                    pixelHeight: previous.pixelHeight,
                    orientation: previous.orientation,
                    captureDate: previous.captureDate
                )
            } else {
                // Duration parsing is deliberately deferred to video playback/detail.
                // Serial AVURLAsset metadata loads made large folders appear stuck.
                duration = nil
                imageMetadata = mediaType == .video ? .empty : Self.imageMetadata(at: candidate.url)
            }

            items.append(
                ExternalMediaItem(
                    stableMediaID: stableMediaID,
                    url: candidate.url,
                    normalizedPath: candidate.normalizedPath,
                    fileResourceIdentifier: candidate.fileResourceIdentifier,
                    pairedVideoURL: pairedVideo?.url,
                    pairedVideoStableID: pairedVideoStableID,
                    pairedVideoPath: pairedVideo?.normalizedPath,
                    mediaType: mediaType,
                    fileSize: fileSize,
                    creationDate: candidate.creationDate,
                    modificationDate: candidate.modificationDate,
                    captureDate: imageMetadata.captureDate,
                    duration: duration,
                    videoDuration: duration,
                    pixelWidth: imageMetadata.pixelWidth,
                    pixelHeight: imageMetadata.pixelHeight,
                    orientation: imageMetadata.orientation,
                    schemaVersion: ExternalMediaIndexStore.currentSchemaVersion
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
        if let folderID {
            let indexStart = ContinuousClock.now
            let currentIDs = Set(sortedItems.map(\.stableMediaID))
            let previousIDs = Set(previousByID.keys)
            let changedItems = sortedItems.filter { item in
                guard let previous = previousByID[item.stableMediaID] else { return true }
                return Self.hasIndexRelevantChange(previous: previous, current: item)
            }
            do {
                try await ExternalMediaIndexStore(folderID: folderID).apply(
                    upserts: changedItems,
                    deletions: previousIDs.subtracting(currentIDs)
                )
            } catch {
                let indexStore = ExternalMediaIndexStore(folderID: folderID)
                try? await indexStore.reset()
                try? await indexStore.replaceAll(with: sortedItems)
            }
            var benchmark = lastIndexBenchmark[folderID] ?? ExternalMediaIndexBenchmark()
            if previousList.isEmpty {
                benchmark.firstScanDuration = scanStart.duration(to: .now)
            }
            benchmark.validationDuration = validationDuration
            benchmark.databaseSizeBytes = await ExternalMediaIndexStore(folderID: folderID).databaseSize()
            lastIndexBenchmark[folderID] = benchmark
            PerformanceLogger.log(
                "external-index-update",
                duration: indexStart.duration(to: .now),
                details: "changed=\(changedItems.count) deleted=\(previousIDs.subtracting(currentIDs).count) dbSize=\(benchmark.databaseSizeBytes ?? 0)"
            )
        }
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
    ) async throws -> [ScanCandidate] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: folderURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ScanError.folderUnavailable
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isHiddenKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .typeIdentifierKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]

        var candidates: [ScanCandidate] = []
        if recursively {
            let urls = try recursiveURLs(in: folderURL, keys: keys)
            for (index, fileURL) in urls.enumerated() {
                let visitedCount = index + 1
                if visitedCount.isMultiple(of: 64) { try Task.checkCancellation() }
                await appendCandidate(fileURL, keys: keys, to: &candidates)
            }
        } else {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            for (index, fileURL) in urls.enumerated() {
                if index.isMultiple(of: 64) { try Task.checkCancellation() }
                await appendCandidate(fileURL, keys: keys, to: &candidates)
            }
        }
        return candidates
    }

    nonisolated private static func recursiveURLs(
        in folderURL: URL,
        keys: Set<URLResourceKey>
    ) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            throw ScanError.folderUnavailable
        }
        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            urls.append(fileURL)
        }
        return urls
    }

    nonisolated private static func appendCandidate(
        _ url: URL,
        keys: Set<URLResourceKey>,
        to candidates: inout [ScanCandidate]
    ) async {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isHidden != true,
              values.isPackage != true,
              values.isSymbolicLink != true,
              values.fileSize.map({ $0 > 0 }) == true,
              !isIncompleteDownload(url),
              isLocalOrDownloaded(values),
              let mediaType = await mediaType(for: url, values: values) else { return }

        candidates.append(
            ScanCandidate(
                url: url,
                normalizedPath: url.resolvingSymlinksInPath().standardizedFileURL.path,
                fileResourceIdentifier: resourceIdentifierString(
                    values.allValues[.fileResourceIdentifierKey]
                ),
                mediaType: mediaType,
                fileSize: values.fileSize.map(Int64.init),
                creationDate: values.creationDate,
                modificationDate: values.contentModificationDate
            )
        )
    }

    nonisolated private static func resourceIdentifierString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let data = value as? Data {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        return String(describing: value)
    }

    nonisolated private static func imageMetadata(at url: URL) -> ImageMetadata {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return .empty }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return .empty }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let pixelSize = (5...8).contains(orientation) ? (height, width) : (width, height)
        return ImageMetadata(
            pixelWidth: pixelSize.0,
            pixelHeight: pixelSize.1,
            orientation: orientation,
            captureDate: captureDate(from: properties)
        )
    }

    nonisolated private static func mediaType(
        for url: URL,
        values: URLResourceValues
    ) async -> ExternalMediaType? {
        guard let typeIdentifier = values.typeIdentifier,
              let type = UTType(typeIdentifier) else { return nil }

        if type.conforms(to: .image), imageFileIsReadable(at: url) {
            return .image
        }

        if (type.conforms(to: .movie) ||
            type.conforms(to: .video) ||
            type.conforms(to: .audiovisualContent)),
           await videoFileHasTrack(at: url) {
            return .video
        }

        return nil
    }

    nonisolated private static func imageFileIsReadable(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    nonisolated private static func videoFileHasTrack(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video) else { return false }
        return !tracks.isEmpty
    }

    nonisolated private static func isIncompleteDownload(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        let fileExtension = url.pathExtension.lowercased()
        return filename.hasSuffix(".download") ||
            ["download", "crdownload", "part", "partial", "tmp"].contains(fileExtension)
    }

    nonisolated private static func isLocalOrDownloaded(_ values: URLResourceValues) -> Bool {
        guard values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current
    }

    nonisolated private static func stableMediaID(
        for candidate: ScanCandidate,
        resourceIdentifierCounts: [String: Int]
    ) -> String {
        if let fileResourceIdentifier = candidate.fileResourceIdentifier,
           resourceIdentifierCounts[fileResourceIdentifier, default: 0] <= 1 {
            return "fileResource:\(fileResourceIdentifier)"
        }
        let mtimeNs = candidate.modificationDate.map {
            Int64(($0.timeIntervalSinceReferenceDate * 1_000_000_000).rounded())
        } ?? 0
        return "path:\(candidate.normalizedPath)#size=\(candidate.fileSize ?? -1)#mtimeNs=\(mtimeNs)"
    }

    nonisolated private static func hasIndexRelevantChange(
        previous: ExternalMediaItem,
        current: ExternalMediaItem
    ) -> Bool {
        previous.normalizedPath != current.normalizedPath ||
            previous.fileResourceIdentifier != current.fileResourceIdentifier ||
            previous.modificationDate != current.modificationDate ||
            previous.fileSize != current.fileSize ||
            previous.mediaType != current.mediaType ||
            previous.pixelWidth != current.pixelWidth ||
            previous.pixelHeight != current.pixelHeight ||
            previous.orientation != current.orientation ||
            previous.captureDate != current.captureDate ||
            previous.creationDate != current.creationDate ||
            previous.videoDuration != current.videoDuration ||
            previous.pairedVideoStableID != current.pairedVideoStableID ||
            previous.pairedVideoPath != current.pairedVideoPath ||
            previous.schemaVersion != current.schemaVersion
    }

    nonisolated private static func captureDate(from properties: [CFString: Any]) -> Date? {
        let candidates = [
            (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String,
            (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeDigitized] as? String,
            (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFDateTime] as? String
        ].compactMap { $0 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return candidates.lazy.compactMap(formatter.date(from:)).first
    }

}

private struct ScanCandidate: Sendable {
    let url: URL
    let normalizedPath: String
    let fileResourceIdentifier: String?
    let mediaType: ExternalMediaType
    let fileSize: Int64?
    let creationDate: Date?
    let modificationDate: Date?
}

nonisolated private struct PairingKey: Hashable {
    let directory: String
    let basename: String
}

private struct ImageMetadata: Sendable {
    nonisolated static let empty = ImageMetadata(
        pixelWidth: nil,
        pixelHeight: nil,
        orientation: nil,
        captureDate: nil
    )

    let pixelWidth: Int?
    let pixelHeight: Int?
    let orientation: Int?
    let captureDate: Date?

    nonisolated init(
        pixelWidth: Int?,
        pixelHeight: Int?,
        orientation: Int?,
        captureDate: Date?
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.captureDate = captureDate
    }
}
