import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main
struct ExternalMediaBenchmark {
    static func main() async throws {
        let scenarios = CommandLine.arguments.dropFirst().compactMap(Int.init)
        for count in scenarios.isEmpty ? PerformanceScenario.defaultCounts : scenarios {
            try await run(scenario: PerformanceScenario(mediaCount: count))
        }
    }

    private static func run(scenario: PerformanceScenario) async throws {
        let count = scenario.mediaCount
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GladPhotosBenchmark-\(count)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seeds = try makeSeeds(in: root)

        let directoryCount = 20
        for directoryIndex in 0..<directoryCount {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("album-\(directoryIndex)"),
                withIntermediateDirectories: true
            )
        }
        for index in 0..<count {
            let album = root.appendingPathComponent("album-\(index % directoryCount)")
            let basename = String(format: "media-%05d", index)
            let seed = scenario.seed(for: index, seeds: seeds)
            let destination = album.appendingPathComponent(basename)
                .appendingPathExtension(seed.pathExtension)
            try FileManager.default.linkItem(at: seed, to: destination)

            if scenario.shouldCreateLivePhotoPair(at: index) {
                let videoDestination = album.appendingPathComponent(basename)
                    .appendingPathExtension("mov")
                try FileManager.default.linkItem(at: seeds.mov, to: videoDestination)
            }
        }

        let folderID = UUID()
        try? await ExternalMediaIndexStore(folderID: folderID).reset()
        let scanner = ExternalMediaScanner()
        let scanStart = ContinuousClock.now
        let items = try await scanner.scan(folderID: folderID, folderURL: root)
        let scanDuration = scanStart.duration(to: .now)
        let databaseSize = await ExternalMediaIndexStore(folderID: folderID).databaseSize() ?? 0

        let restoreScanner = ExternalMediaScanner()
        let restoreStart = ContinuousClock.now
        let restoredSnapshot = await restoreScanner.indexedItems(folderID: folderID, folderURL: root)
        let restoreDuration = restoreStart.duration(to: .now)
        let publishStart = ContinuousClock.now
        await MainActor.run {
            _ = restoredSnapshot?.items.count ?? 0
        }
        let mainThreadPublishDuration = publishStart.duration(to: .now)

        let validationStart = ContinuousClock.now
        let validatedItems = try await restoreScanner.scan(folderID: folderID, folderURL: root)
        let validationDuration = validationStart.duration(to: .now)
        let thumbnailItems = items.isEmpty ? try benchmarkThumbnailItems(in: root) : items

        let firstScreen = Array(thumbnailItems.filter { ($0.fileSize ?? 0) > 8 }.prefix(48))
        let diskBenchmarkRoot = root.appendingPathComponent(".thumbnail-benchmark-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: diskBenchmarkRoot)
        let coldService = await MainActor.run {
            ExternalThumbnailService(diskCache: ExternalDiskThumbnailCache(rootURL: diskBenchmarkRoot))
        }
        let coldFirstScreenStart = ContinuousClock.now
        let coldFirstScreenDecoded = await load(firstScreen, pixelSize: 320, service: coldService)
        let coldFirstScreenDuration = coldFirstScreenStart.duration(to: .now)
        let coldDiskStats = await coldService.diskCacheStatistics()

        let restartedService = await MainActor.run {
            ExternalThumbnailService(diskCache: ExternalDiskThumbnailCache(rootURL: diskBenchmarkRoot))
        }
        let warmFirstScreenStart = ContinuousClock.now
        let warmFirstScreenDecoded = await load(firstScreen, pixelSize: 320, service: restartedService)
        let warmFirstScreenDuration = warmFirstScreenStart.duration(to: .now)
        let warmDiskStats = await restartedService.diskCacheStatistics()

        await MainActor.run {
            coldService.removeAllCachedImages()
        }
        await coldService.resetDiskCacheStatistics()
        let memoryClearedStart = ContinuousClock.now
        let memoryClearedDecoded = await load(firstScreen, pixelSize: 320, service: coldService)
        let memoryClearedDuration = memoryClearedStart.duration(to: .now)
        let memoryClearedDiskStats = await coldService.diskCacheStatistics()

        // Scroll proxy: process successive visible windows while retaining no images.
        // The app itself uses the same decoder and cancels windows that disappear.
        let scrollSample = Array(thumbnailItems.prefix(min(thumbnailItems.count, 240)))
        let scrollStart = ContinuousClock.now
        var decodedDuringScroll = 0
        for offset in stride(from: 0, to: scrollSample.count, by: 48) {
            let end = min(offset + 48, scrollSample.count)
            decodedDuringScroll += await decode(Array(scrollSample[offset..<end]), pixelSize: 320)
        }
        let scrollDuration = scrollStart.duration(to: .now)
        let cancellationRecovery = await measureCancellationRecovery(
            items: thumbnailItems,
            folderURL: root,
            seedURL: seeds.jpeg
        )
        let regressionItems = thumbnailItems.filter { item in
            item.mediaType != .video && (item.fileSize ?? 0) > 8
        }
        let returnVisitRegression = await ExternalThumbnailService()
            .runReturnVisitRegressionProbe(items: regressionItems)

        print("scenario=\(scenario.name)")
        print("dataset=\(count) files root=\(root.path)")
        print("mix=\(scenario.mixDescription)")
        print("first_scan_index_build=\(format(scanDuration)) discovered=\(items.count)")
        print("second_open_index_restore=\(format(restoreDuration)) restored=\(restoredSnapshot?.items.count ?? 0)")
        print("background_validation=\(format(validationDuration)) validated=\(validatedItems.count)")
        print("thumbnail_benchmark_items=\(thumbnailItems.count)")
        print("main_thread_publish=\(format(mainThreadPublishDuration))")
        print(String(format: "index_database_size=%.2f MB bytes=%lld", Double(databaseSize) / 1_048_576, databaseSize))
        print("first_screen_cold_disk_build=\(format(coldFirstScreenDuration)) loaded=\(coldFirstScreenDecoded)/\(firstScreen.count)")
        print("first_screen_after_full_restart=\(format(warmFirstScreenDuration)) loaded=\(warmFirstScreenDecoded)/\(firstScreen.count)")
        print("first_screen_memory_cleared_disk_warm=\(format(memoryClearedDuration)) loaded=\(memoryClearedDecoded)/\(firstScreen.count)")
        print(
            "disk_cold=hits=\(coldDiskStats.diskExactHits + coldDiskStats.diskLargerHits + coldDiskStats.diskSmallerHits) " +
            "misses=\(coldDiskStats.diskMisses) image_decodes=\(coldDiskStats.sourceImageDecodes) " +
            "video_generations=\(coldDiskStats.sourceVideoGenerations) writes=\(coldDiskStats.diskWrites) " +
            "bytes=\(coldDiskStats.diskCacheBytes)"
        )
        print(
            "disk_restart=exact=\(warmDiskStats.diskExactHits) larger=\(warmDiskStats.diskLargerHits) smaller=\(warmDiskStats.diskSmallerHits) " +
            "misses=\(warmDiskStats.diskMisses) image_decodes=\(warmDiskStats.sourceImageDecodes) " +
            "video_generations=\(warmDiskStats.sourceVideoGenerations) bytes=\(warmDiskStats.diskCacheBytes)"
        )
        print(
            "disk_memory_cleared=exact=\(memoryClearedDiskStats.diskExactHits) larger=\(memoryClearedDiskStats.diskLargerHits) " +
            "smaller=\(memoryClearedDiskStats.diskSmallerHits) misses=\(memoryClearedDiskStats.diskMisses) " +
            "image_decodes=\(memoryClearedDiskStats.sourceImageDecodes) " +
            "video_generations=\(memoryClearedDiskStats.sourceVideoGenerations) bytes=\(memoryClearedDiskStats.diskCacheBytes)"
        )
        print("scroll_proxy=\(format(scrollDuration)) decoded=\(decodedDuringScroll)/\(scrollSample.count)")
        print("cancel_recovery=\(format(cancellationRecovery))")
        print(
            "return_regression=immediate \(returnVisitRegression.returnPassImmediateImages)/\(returnVisitRegression.returnPassTotalImages) " +
            "misses=\(returnVisitRegression.returnPassMisses) new_decodes=\(returnVisitRegression.returnPassDecodedRequests)"
        )
        print("thumbnail_cache=\(returnVisitRegression.stats.summary)")
        print(String(format: "resident_memory=%.1f MB", residentMemoryMB()))
    }

    private static func benchmarkThumbnailItems(in root: URL) throws -> [ExternalMediaItem] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isHiddenKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var items: [ExternalMediaItem] = []
        for case let url as URL in enumerator {
            guard !url.standardizedFileURL.path.contains("/.thumbnail-benchmark-cache/") else {
                continue
            }
            let mediaType: ExternalMediaType?
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg", "png", "heic", "heif":
                mediaType = .image
            case "mov", "mp4", "m4v":
                mediaType = .video
            default:
                mediaType = nil
            }
            guard let mediaType else { continue }
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isHiddenKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            guard values?.isRegularFile == true, values?.isHidden != true else { continue }
            items.append(
                ExternalMediaItem(
                    url: url,
                    pairedVideoURL: nil,
                    mediaType: mediaType,
                    fileSize: values?.fileSize.map(Int64.init),
                    creationDate: nil,
                    modificationDate: values?.contentModificationDate,
                    duration: mediaType == .video ? 3 : nil,
                    pixelWidth: 1_600,
                    pixelHeight: 1_200
                )
            )
        }
        return items.sorted {
            ($0.modificationDate ?? .distantPast, $0.url.path) <
                ($1.modificationDate ?? .distantPast, $1.url.path)
        }
    }

    @MainActor
    private static func load(
        _ items: [ExternalMediaItem],
        pixelSize: CGFloat,
        service: ExternalThumbnailService
    ) async -> Int {
        var loaded = 0
        for offset in stride(from: 0, to: items.count, by: 6) {
            let end = min(offset + 6, items.count)
            loaded += await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for item in items[offset..<end] {
                    group.addTask { @MainActor in
                        await service.image(for: item, maxPixelSize: pixelSize) != nil
                    }
                }
                var batchLoaded = 0
                for await succeeded in group where succeeded { batchLoaded += 1 }
                return batchLoaded
            }
        }
        return loaded
    }

    @MainActor
    private static func measureCancellationRecovery(
        items: [ExternalMediaItem],
        folderURL: URL,
        seedURL: URL
    ) async -> Duration {
        let service = ExternalThumbnailService()
        for item in items.prefix(200) {
            Task { _ = await service.image(for: item, maxPixelSize: 320) }
        }
        await Task.yield()
        service.cancelRequests(in: folderURL)

        let recoveryURL = folderURL.deletingLastPathComponent()
            .appendingPathComponent("GladPhotosRecovery-\(UUID().uuidString).jpg")
        try? FileManager.default.linkItem(at: seedURL, to: recoveryURL)
        defer { try? FileManager.default.removeItem(at: recoveryURL) }
        let recoveryItem = ExternalMediaItem(
            url: recoveryURL,
            pairedVideoURL: nil,
            mediaType: .image,
            fileSize: nil,
            creationDate: nil,
            modificationDate: nil,
            duration: nil,
            pixelWidth: 1_600,
            pixelHeight: 1_200
        )
        let start = ContinuousClock.now
        _ = await service.image(for: recoveryItem, maxPixelSize: 320)
        return start.duration(to: .now)
    }

    private static func decode(_ items: [ExternalMediaItem], pixelSize: CGFloat) async -> Int {
        var decoded = 0
        for offset in stride(from: 0, to: items.count, by: 6) {
            let end = min(offset + 6, items.count)
            decoded += await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for item in items[offset..<end] {
                    group.addTask {
                        autoreleasepool {
                            ExternalImagePipeline.thumbnail(
                                url: item.url,
                                requestedPixelSize: Int(pixelSize),
                                preferEmbedded: true
                            ) != nil
                        }
                    }
                }
                var batchDecoded = 0
                for await succeeded in group where succeeded { batchDecoded += 1 }
                return batchDecoded
            }
        }
        return decoded
    }

    private static func makeSeeds(in root: URL) throws -> BenchmarkSeeds {
        let seedRoot = root.deletingLastPathComponent()
            .appendingPathComponent("GladPhotosBenchmarkSeeds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: seedRoot, withIntermediateDirectories: true)
        let jpeg = seedRoot.appendingPathComponent("seed.jpg")
        let png = seedRoot.appendingPathComponent("seed-large.png")
        let corrupt = seedRoot.appendingPathComponent("seed-corrupt.jpg")
        let mov = seedRoot.appendingPathComponent("seed.mov")
        try makeSeedImage(at: jpeg, uti: UTType.jpeg.identifier as CFString)
        try makeSeedImage(at: png, uti: UTType.png.identifier as CFString, width: 6_000, height: 4_000)
        try Data([0, 1, 2, 3, 4, 5, 6, 7]).write(to: corrupt)
        try Data("GladPhotos benchmark placeholder movie".utf8).write(to: mov)
        return BenchmarkSeeds(jpeg: jpeg, png: png, corrupt: corrupt, mov: mov)
    }

    private static func makeSeedImage(
        at url: URL,
        uti: CFString,
        width: Int = 1_600,
        height: Int = 1_200
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
           let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            uti,
            1,
            nil
           ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
            kCGImageDestinationEmbedThumbnail: true
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    private static func format(_ duration: Duration) -> String {
        String(format: "%.3fs", Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18)
    }
}

private struct PerformanceScenario {
    static let defaultCounts = [1_000, 10_000, 50_000]

    let mediaCount: Int
    var name: String { "\(mediaCount)-mixed-media" }
    var mixDescription: String {
        "jpg baseline, every 25th large png, every 40th mov, every 50th live-photo pair, every 97th corrupt jpg"
    }

    func seed(for index: Int, seeds: BenchmarkSeeds) -> URL {
        if index.isMultiple(of: 97) { return seeds.corrupt }
        if index.isMultiple(of: 40) { return seeds.mov }
        if index.isMultiple(of: 25) { return seeds.png }
        return seeds.jpeg
    }

    func shouldCreateLivePhotoPair(at index: Int) -> Bool {
        index.isMultiple(of: 50) && !index.isMultiple(of: 40)
    }
}

private struct BenchmarkSeeds {
    let jpeg: URL
    let png: URL
    let corrupt: URL
    let mov: URL
}
