import AppKit
import Foundation
import XCTest
@testable import GladPhotos

@MainActor
final class ExternalDiskThumbnailCacheTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() async throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        try await super.tearDown()
    }

    func testFirstGenerationPersistsAndMemoryClearHitsDisk() async throws {
        let cache = try makeCache()
        let counter = ThumbnailGenerationCounter()
        let item = try makeItem(stableID: "stable-image-1", mediaType: .image)
        let service = makeService(cache: cache, counter: counter)

        let firstImage = await service.image(for: item, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(firstImage)
        var diskStats = await service.diskCacheStatistics()
        XCTAssertEqual(diskStats.sourceImageDecodes, 1)
        XCTAssertEqual(diskStats.diskWrites, 1)

        service.removeAllCachedImages()
        await service.resetDiskCacheStatistics()
        await counter.reset()

        let diskImage = await service.image(for: item, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(diskImage)
        diskStats = await service.diskCacheStatistics()
        let imageCount = await counter.imageCount()
        XCTAssertEqual(imageCount, 0)
        XCTAssertEqual(diskStats.sourceImageDecodes, 0)
        XCTAssertEqual(diskStats.diskExactHits, 1)

        let key = ExternalDiskThumbnailKey(item: item, tier: .preview)
        let storedRelativePath = await cache.relativePathForTests(cacheKey: key.cacheKey)
        let relativePath = try XCTUnwrap(storedRelativePath)
        XCTAssertFalse(relativePath.contains(item.url.path))
        XCTAssertTrue(relativePath.hasSuffix(".jpg") || relativePath.hasSuffix(".png"))
    }

    func testSimulatedRestartHitsDiskForImageAndVideoWithoutSourceGeneration() async throws {
        let rootURL = try makeTemporaryDirectory()
        let imageCache = ExternalDiskThumbnailCache(rootURL: rootURL)
        let imageCounter = ThumbnailGenerationCounter()
        let imageItem = try makeItem(stableID: "stable-image-restart", mediaType: .image)
        let firstService = makeService(cache: imageCache, counter: imageCounter)
        let firstImage = await firstService.image(for: imageItem, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(firstImage)

        let restartedImageCache = ExternalDiskThumbnailCache(rootURL: rootURL)
        let restartedImageCounter = ThumbnailGenerationCounter()
        let restartedImageService = makeService(cache: restartedImageCache, counter: restartedImageCounter)
        let restartedImage = await restartedImageService.image(for: imageItem, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(restartedImage)
        var restartedStats = await restartedImageService.diskCacheStatistics()
        let restartedImageCount = await restartedImageCounter.imageCount()
        XCTAssertEqual(restartedImageCount, 0)
        XCTAssertEqual(restartedStats.sourceImageDecodes, 0)
        XCTAssertEqual(restartedStats.diskExactHits, 1)

        let videoItem = try makeItem(stableID: "stable-video-restart", mediaType: .video)
        let firstVideo = await firstService.image(for: videoItem, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(firstVideo)
        let secondRestartService = makeService(cache: ExternalDiskThumbnailCache(rootURL: rootURL), counter: restartedImageCounter)
        await restartedImageCounter.reset()
        let restartedVideo = await secondRestartService.image(for: videoItem, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(restartedVideo)
        restartedStats = await secondRestartService.diskCacheStatistics()
        let restartedVideoCount = await restartedImageCounter.videoCount()
        XCTAssertEqual(restartedVideoCount, 0)
        XCTAssertEqual(restartedStats.sourceVideoGenerations, 0)
        XCTAssertEqual(restartedStats.diskExactHits, 1)
    }

    func testSourceModificationInvalidatesAndStableRenameContinuesToHit() async throws {
        let cache = try makeCache()
        let counter = ThumbnailGenerationCounter()
        let original = try makeItem(stableID: "stable-rename", mediaType: .image, filename: "original.dat")
        let service = makeService(cache: cache, counter: counter)
        let originalImage = await service.image(for: original, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(originalImage)

        service.removeAllCachedImages()
        await service.resetDiskCacheStatistics()
        await counter.reset()
        let renamed = try makeItem(
            stableID: "stable-rename",
            mediaType: .image,
            filename: "renamed.dat",
            fileSize: original.fileSize,
            modificationDate: original.modificationDate
        )
        let renamedImage = await service.image(for: renamed, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(renamedImage)
        var stats = await service.diskCacheStatistics()
        XCTAssertEqual(stats.diskExactHits, 1)
        let renamedImageCount = await counter.imageCount()
        XCTAssertEqual(renamedImageCount, 0)

        service.removeAllCachedImages()
        await service.resetDiskCacheStatistics()
        await counter.reset()
        let modified = try makeItem(
            stableID: "stable-rename",
            mediaType: .image,
            filename: "modified.dat",
            fileSize: (original.fileSize ?? 0) + 1,
            modificationDate: (original.modificationDate ?? Date()).addingTimeInterval(1)
        )
        let modifiedImage = await service.image(for: modified, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(modifiedImage)
        stats = await service.diskCacheStatistics()
        XCTAssertEqual(stats.diskMisses, 1)
        XCTAssertEqual(stats.sourceImageDecodes, 1)
    }

    func testTierReuseAndCorruptCacheRebuild() async throws {
        let cache = try makeCache()
        let counter = ThumbnailGenerationCounter()
        let item = try makeItem(stableID: "stable-tier", mediaType: .image)
        let service = makeService(cache: cache, counter: counter)

        let largeImage = await service.image(for: item, maxPixelSize: CGFloat(ThumbnailTier.large.pixels))
        XCTAssertNotNil(largeImage)
        service.removeAllCachedImages()
        await service.resetDiskCacheStatistics()
        await counter.reset()
        let largerHitImage = await service.image(for: item, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(largerHitImage)
        var stats = await service.diskCacheStatistics()
        XCTAssertEqual(stats.diskLargerHits, 1)
        let largerHitImageCount = await counter.imageCount()
        XCTAssertEqual(largerHitImageCount, 0)

        let corruptItem = try makeItem(stableID: "stable-corrupt", mediaType: .image)
        service.removeAllCachedImages()
        await service.resetDiskCacheStatistics()
        let previewImage = await service.image(for: corruptItem, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(previewImage)
        service.removeAllCachedImages()
        let key = ExternalDiskThumbnailKey(item: corruptItem, tier: .preview)
        let storedRelativePath = await cache.relativePathForTests(cacheKey: key.cacheKey)
        let relativePath = try XCTUnwrap(storedRelativePath)
        let corruptURL = await cache.url.appendingPathComponent(relativePath)
        try Data("not an image".utf8).write(to: corruptURL)
        await counter.reset()
        await service.resetDiskCacheStatistics()
        let rebuiltImage = await service.image(for: corruptItem, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(rebuiltImage)
        stats = await service.diskCacheStatistics()
        XCTAssertEqual(stats.diskReadFailures, 1)
        XCTAssertEqual(stats.sourceImageDecodes, 1)
        XCTAssertEqual(stats.diskWrites, 1)
    }

    func testSmallerTierImmediateHitThenSupplementsTargetTier() async throws {
        let cache = try makeCache()
        let counter = ThumbnailGenerationCounter()
        let item = try makeItem(stableID: "stable-smaller-tier", mediaType: .image)
        let service = makeService(cache: cache, counter: counter)

        let previewImage = await service.image(for: item, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(previewImage)
        service.removeAllCachedImages()
        await service.resetDiskCacheStatistics()
        await counter.reset()

        let largeImage = await service.image(for: item, maxPixelSize: CGFloat(ThumbnailTier.large.pixels))
        XCTAssertNotNil(largeImage)
        try await Task.sleep(for: .milliseconds(100))
        let stats = await service.diskCacheStatistics()
        XCTAssertEqual(stats.diskSmallerHits, 1)
        XCTAssertGreaterThanOrEqual(stats.sourceImageDecodes, 1)
    }

    func testConcurrentSameKeyGeneratesAndWritesOnce() async throws {
        let cache = try makeCache()
        let counter = ThumbnailGenerationCounter(delayNanoseconds: 80_000_000)
        let item = try makeItem(stableID: "stable-concurrent", mediaType: .image)
        let service = makeService(cache: cache, counter: counter)

        let tasks = (0..<3).map { _ in
            Task { @MainActor in
                await service.image(for: item, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
            }
        }
        var results: [NSImage?] = []
        for task in tasks {
            results.append(await task.value)
        }
        XCTAssertEqual(results.compactMap { $0 }.count, 3)

        let stats = await service.diskCacheStatistics()
        let generatedImages = await counter.imageCount()
        XCTAssertEqual(generatedImages, 1)
        XCTAssertEqual(stats.sourceImageDecodes, 1)
        XCTAssertEqual(stats.diskWrites, 1)
        XCTAssertEqual(stats.coalescedRequests, 2)
    }

    func testCacheDirectoryDeletionAndManifestCorruptionRecoverSafely() async throws {
        let rootURL = try makeTemporaryDirectory()
        let counter = ThumbnailGenerationCounter()
        let item = try makeItem(stableID: "stable-recovery", mediaType: .image)
        let service = makeService(cache: ExternalDiskThumbnailCache(rootURL: rootURL), counter: counter)
        let firstImage = await service.image(for: item, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(firstImage)

        try FileManager.default.removeItem(at: rootURL)
        service.removeAllCachedImages()
        await service.resetDiskCacheStatistics()
        let recreatedImage = await service.image(for: item, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(recreatedImage)
        var stats = await service.diskCacheStatistics()
        XCTAssertEqual(stats.diskWrites, 1)

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("broken sqlite".utf8).write(to: rootURL.appendingPathComponent("manifest.sqlite"))
        let recoveredService = makeService(cache: ExternalDiskThumbnailCache(rootURL: rootURL), counter: counter)
        await counter.reset()
        let recoveredImage = await recoveredService.image(for: item, maxPixelSize: CGFloat(ThumbnailTier.preview.pixels))
        XCTAssertNotNil(recoveredImage)
        stats = await recoveredService.diskCacheStatistics()
        XCTAssertEqual(stats.sourceImageDecodes, 1)
        XCTAssertEqual(stats.diskWrites, 1)
    }

    func testManifestHasRequiredLightweightSchema() async throws {
        let cache = try makeCache()
        let item = try makeItem(stableID: "stable-schema", mediaType: .image)
        await cache.store(makeImage(width: 96, height: 64, color: .systemPurple), for: ExternalDiskThumbnailKey(item: item, tier: .preview))

        let columns = await cache.manifestColumnsForTests()
        XCTAssertTrue(columns.contains("cacheKey"))
        XCTAssertTrue(columns.contains("stableMediaID"))
        XCTAssertTrue(columns.contains("tier"))
        XCTAssertTrue(columns.contains("mediaKind"))
        XCTAssertTrue(columns.contains("relativePath"))
        XCTAssertTrue(columns.contains("byteSize"))
        XCTAssertTrue(columns.contains("lastAccess"))
        XCTAssertTrue(columns.contains("sourceVersion"))
        XCTAssertTrue(columns.contains("renderingVersion"))
    }

    func testOverCapacityCleanupDeletesOldestEntries() async throws {
        let cache = try makeCache(byteLimit: 900, cleanupTargetBytes: 500)
        for index in 0..<6 {
            let item = try makeItem(stableID: "stable-cleanup-\(index)", mediaType: .image)
            await cache.store(makeImage(width: 96, height: 96, color: .systemBlue), for: ExternalDiskThumbnailKey(item: item, tier: .preview))
        }

        await cache.cleanupNowForTests()
        let stats = await cache.statistics()
        XCTAssertGreaterThan(stats.cleanupFreedBytes, 0)
        XCTAssertLessThanOrEqual(stats.diskCacheBytes, 900)
    }

    private func makeService(
        cache: ExternalDiskThumbnailCache,
        counter: ThumbnailGenerationCounter
    ) -> ExternalThumbnailService {
        ExternalThumbnailService(
            diskCache: cache,
            imageGenerator: { _, pixels, _ in
                await counter.generateImage(pixels: pixels)
            },
            videoGenerator: { _, pixels in
                await counter.generateVideo(pixels: pixels)
            }
        )
    }

    private func makeCache(
        byteLimit: Int64 = 2 * 1024 * 1024 * 1024,
        cleanupTargetBytes: Int64 = Int64(Double(2 * 1024 * 1024 * 1024) * 0.8)
    ) throws -> ExternalDiskThumbnailCache {
        ExternalDiskThumbnailCache(
            rootURL: try makeTemporaryDirectory(),
            byteLimit: byteLimit,
            cleanupTargetBytes: cleanupTargetBytes
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GladPhotosDiskThumbnailCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeItem(
        stableID: String,
        mediaType: ExternalMediaType,
        filename: String = "media.dat",
        fileSize: Int64? = nil,
        modificationDate: Date? = nil
    ) throws -> ExternalMediaItem {
        let folder = try makeTemporaryDirectory()
        let url = folder.appendingPathComponent(filename)
        let size = fileSize ?? 1_024
        try Data(repeating: UInt8(size % 251), count: Int(size)).write(to: url)
        let modificationDate = modificationDate ?? Date(timeIntervalSinceReferenceDate: 800_000 + Double(temporaryURLs.count))
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        return ExternalMediaItem(
            stableMediaID: stableID,
            url: url,
            pairedVideoURL: nil,
            mediaType: mediaType,
            fileSize: size,
            creationDate: modificationDate,
            modificationDate: modificationDate,
            duration: mediaType == .video ? 3 : nil,
            pixelWidth: 1_600,
            pixelHeight: 1_200
        )
    }
}

private actor ThumbnailGenerationCounter {
    private var images = 0
    private var videos = 0
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    func generateImage(pixels: Int) async -> NSImage {
        images += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return makeImage(width: pixels, height: max(1, pixels * 3 / 4), color: .systemRed)
    }

    func generateVideo(pixels: Int) async -> NSImage {
        videos += 1
        return makeImage(width: pixels, height: max(1, pixels * 9 / 16), color: .systemGreen)
    }

    func imageCount() -> Int { images }
    func videoCount() -> Int { videos }

    func reset() {
        images = 0
        videos = 0
    }
}

nonisolated private func makeImage(width: Int, height: Int, color: NSColor) -> NSImage {
    let image = NSImage(size: CGSize(width: width, height: height))
    image.lockFocus()
    color.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()
    return image
}
