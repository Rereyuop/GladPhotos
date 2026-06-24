import AVFoundation
import AppKit
import ImageIO

enum ExternalThumbnailSizing: String, Sendable {
    case longestEdge
    case displayWidth
    case squareCell
}

enum ThumbnailTier: Int, CaseIterable, Sendable {
    case preview = 320
    case small = 480
    case medium = 640
    case large = 960
    case extraLarge = 1280
    case maximum = 1600

    nonisolated var pixels: Int { rawValue }

    nonisolated static func fitting(_ requestedPixels: CGFloat) -> ThumbnailTier {
        let bounded = min(CGFloat(maximum.pixels), max(1, requestedPixels))
        return allCases.first { CGFloat($0.pixels) >= bounded } ?? .maximum
    }
}

enum ExternalThumbnailRequestPriority: Sendable {
    case visible
    case preheat
    case finalUpgrade

    var taskPriority: TaskPriority {
        switch self {
        case .visible: .userInitiated
        case .preheat, .finalUpgrade: .utility
        }
    }
}

@MainActor
final class ExternalMediaScrollDiagnostics {
    static let shared = ExternalMediaScrollDiagnostics()

    private var task: Task<Void, Never>?
    private var visibleCount = 0
    private var preheatCount = 0
    private var previewRequests = 0
    private var finalRequests = 0
    private var memoryHits = 0
    private var diskHits = 0
    private var sharedReuses = 0
    private var underlyingCancels = 0
    private var discardedFinals = 0

    func recordViewport(visible: Int, preheat: Int) {
        visibleCount = visible
        preheatCount = preheat
        ensureLogging()
    }

    func recordRequest(priority: ExternalThumbnailRequestPriority) {
        switch priority {
        case .finalUpgrade:
            finalRequests += 1
        case .visible, .preheat:
            previewRequests += 1
        }
        ensureLogging()
    }

    func recordMemoryHit() {
        memoryHits += 1
        ensureLogging()
    }

    func recordDiskHit() {
        diskHits += 1
        ensureLogging()
    }

    func recordSharedReuse() {
        sharedReuses += 1
        ensureLogging()
    }

    func recordUnderlyingCancel() {
        underlyingCancels += 1
        ensureLogging()
    }

    func recordDiscardedFinal() {
        discardedFinals += 1
        ensureLogging()
    }

    private func ensureLogging() {
        #if DEBUG
        guard task == nil else { return }
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                flush()
            }
        }
        #endif
    }

    private func flush() {
        #if DEBUG
        guard visibleCount > 0 || preheatCount > 0 || previewRequests > 0 ||
            finalRequests > 0 || memoryHits > 0 || diskHits > 0 ||
            sharedReuses > 0 || underlyingCancels > 0 || discardedFinals > 0
        else { return }
        PerformanceLogger.log(
            "external-scroll-diagnostics",
            duration: .zero,
            details: "visible=\(visibleCount) preheat=\(preheatCount) previewReqPerSec=\(previewRequests) finalReqPerSec=\(finalRequests) memoryHitsPerSec=\(memoryHits) diskHitsPerSec=\(diskHits) sharedReusePerSec=\(sharedReuses) underlyingCancelsPerSec=\(underlyingCancels) discardedFinalsPerSec=\(discardedFinals)"
        )
        previewRequests = 0
        finalRequests = 0
        memoryHits = 0
        diskHits = 0
        sharedReuses = 0
        underlyingCancels = 0
        discardedFinals = 0
        #endif
    }
}

@MainActor
final class ExternalMediaStartupDiagnostics {
    static let shared = ExternalMediaStartupDiagnostics()

    private struct Window {
        let id: UUID
        let startedAt: ContinuousClock.Instant
        var cellCreations = 0
        var onAppearCount = 0
        var previewRequests = 0
        var finalRequests = 0
        var maxThumbnailTasks = 0
        var activeThumbnailTasks = 0
        var maxImageQueue = 0
        var maxVideoQueue = 0
        var decodeCompletions = 0
        var videoCompletions = 0
        var cancels = 0
        var snapshotApplyMilliseconds: Double = 0
        var maxMainThreadStallMilliseconds: Double = 0
        var scrollToLatestCalls = 0
        var scrollToLatestMilliseconds: Double = 0
        var videoDurations: [Double] = []
        var videoTimeouts = 0
    }

    private var window: Window?
    private var monitorTask: Task<Void, Never>?
    private let clock = ContinuousClock()

    func start(itemCount: Int, folderURL: URL?) {
        let id = UUID()
        window = Window(id: id, startedAt: clock.now)
        monitorTask?.cancel()
        monitorTask = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let now = ContinuousClock.now
                let elapsed = previous.duration(to: now).gpMilliseconds
                previous = now
                recordMainThreadStall(max(0, elapsed - 100))
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard self.window?.id == id else { return }
            self.finish(itemCount: itemCount, folderURL: folderURL)
        }
    }

    func recordCellCreated() { window?.cellCreations += 1 }
    func recordOnAppear() { window?.onAppearCount += 1 }
    func recordPreviewRequest() { window?.previewRequests += 1 }
    func recordFinalRequest() { window?.finalRequests += 1 }
    func recordCancel() { window?.cancels += 1 }

    func recordTaskCreated(active: Int) {
        guard var snapshot = window else { return }
        snapshot.activeThumbnailTasks = active
        snapshot.maxThumbnailTasks = max(snapshot.maxThumbnailTasks, active)
        window = snapshot
    }

    func recordTaskFinished(active: Int) {
        window?.activeThumbnailTasks = active
    }

    func recordQueues(image: Int, video: Int) {
        guard var snapshot = window else { return }
        snapshot.maxImageQueue = max(snapshot.maxImageQueue, image)
        snapshot.maxVideoQueue = max(snapshot.maxVideoQueue, video)
        window = snapshot
    }

    func recordDecodeCompleted(isVideo: Bool, milliseconds: Double?, timedOut: Bool = false) {
        window?.decodeCompletions += 1
        if isVideo {
            window?.videoCompletions += 1
            if let milliseconds { window?.videoDurations.append(milliseconds) }
            if timedOut { window?.videoTimeouts += 1 }
        }
    }

    func recordSnapshotApply(_ duration: Duration) {
        window?.snapshotApplyMilliseconds += duration.gpMilliseconds
    }

    func recordMainThreadStall(_ milliseconds: Double) {
        guard var snapshot = window else { return }
        snapshot.maxMainThreadStallMilliseconds = max(snapshot.maxMainThreadStallMilliseconds, milliseconds)
        window = snapshot
    }

    func recordScrollToLatest(_ duration: Duration) {
        window?.scrollToLatestCalls += 1
        window?.scrollToLatestMilliseconds += duration.gpMilliseconds
    }

    private func finish(itemCount: Int, folderURL: URL?) {
        monitorTask?.cancel()
        monitorTask = nil
        guard let snapshot = window else { return }
        window = nil
        let sortedVideoDurations = snapshot.videoDurations.sorted()
        let averageVideo = sortedVideoDurations.isEmpty
            ? 0
            : sortedVideoDurations.reduce(0, +) / Double(sortedVideoDurations.count)
        let p95Index = sortedVideoDurations.isEmpty
            ? 0
            : min(sortedVideoDurations.count - 1, Int(Double(sortedVideoDurations.count - 1) * 0.95))
        let p95Video = sortedVideoDurations.isEmpty ? 0 : sortedVideoDurations[p95Index]
        let maxVideo = sortedVideoDurations.last ?? 0
        PerformanceLogger.log(
            "external-startup-diagnostics",
            duration: snapshot.startedAt.duration(to: clock.now),
            details: String(format:
                "folder=%@ items=%d cells=%d appears=%d preview=%d final=%d maxTasks=%d maxImageQueue=%d maxVideoQueue=%d completed=%d cancels=%d snapshotApply=%.2fms maxMainStall=%.2fms scrollToLatestCalls=%d scrollToLatest=%.2fms videoAvg=%.2fms videoP95=%.2fms videoMax=%.2fms videoTimeouts=%d",
                folderURL?.lastPathComponent ?? "unknown",
                itemCount,
                snapshot.cellCreations,
                snapshot.onAppearCount,
                snapshot.previewRequests,
                snapshot.finalRequests,
                snapshot.maxThumbnailTasks,
                snapshot.maxImageQueue,
                snapshot.maxVideoQueue,
                snapshot.decodeCompletions,
                snapshot.cancels,
                snapshot.snapshotApplyMilliseconds,
                snapshot.maxMainThreadStallMilliseconds,
                snapshot.scrollToLatestCalls,
                snapshot.scrollToLatestMilliseconds,
                averageVideo,
                p95Video,
                maxVideo,
                snapshot.videoTimeouts
            )
        )
    }
}

struct ExternalThumbnailCacheStats: Sendable {
    var exactHits = 0
    var largerTierHits = 0
    var smallerTierHits = 0
    var misses = 0
    var decodedRequests = 0
    var evictions = 0

    var hits: Int { exactHits + largerTierHits + smallerTierHits }
    var lookups: Int { hits + misses }
    var hitRate: Double {
        guard lookups > 0 else { return 0 }
        return Double(hits) / Double(lookups)
    }

    var summary: String {
        String(format:
            "lookups=%d hits=%d exact=%d larger=%d smaller=%d misses=%d hitRate=%.1f%% decodes=%d evictions=%d",
            lookups, hits, exactHits, largerTierHits, smallerTierHits, misses,
            hitRate * 100, decodedRequests, evictions
        )
    }
}

struct ExternalThumbnailRegressionResult: Sendable {
    let firstPassDecodedRequests: Int
    let returnPassDecodedRequests: Int
    let returnPassMisses: Int
    let returnPassImmediateImages: Int
    let returnPassTotalImages: Int
    let stats: ExternalThumbnailCacheStats
}

struct ExternalThumbnailLRUStats: Sendable {
    let uniqueMediaCount: Int
    let objectCount: Int
}

struct ExternalThumbnailCacheIdentity: Hashable, Sendable {
    let mediaKey: String
    let tier: ThumbnailTier

    var cacheKey: String { "\(mediaKey)#tier=\(tier.pixels)" }
}

/// Visible-media thumbnail scheduler. The cache and in-flight table live on the
/// main actor; decoding itself is bounded and runs off actor.
@MainActor
final class ExternalThumbnailService {
    struct CachedThumbnail {
        let image: NSImage
        let tier: ThumbnailTier
        let satisfiesRequestedTier: Bool
    }

    private struct LoadResult: Sendable {
        let image: NSImage?
        let tier: ThumbnailTier
        let cameFromSource: Bool
        let wasSmallerDiskHit: Bool
    }

    typealias ImageGenerator = @Sendable (ExternalMediaItem, Int, Bool) async -> NSImage?
    typealias VideoGenerator = @Sendable (ExternalMediaItem, Int) async -> NSImage?

    private final class Request {
        let id: UUID
        let itemURL: URL
        let task: Task<LoadResult, Never>
        var subscribers: Int

        init(id: UUID, itemURL: URL, task: Task<LoadResult, Never>, subscribers: Int) {
            self.id = id
            self.itemURL = itemURL
            self.task = task
            self.subscribers = subscribers
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let cacheDelegate = ThumbnailCacheDelegate()
    private let recentThumbnails = RecentThumbnailLRU(capacity: 400)
    private var requests: [String: Request] = [:]
    private var durationCache: [String: TimeInterval] = [:]
    private var videoFailureCooldownUntil: [String: Date] = [:]
    private var stats = ExternalThumbnailCacheStats()
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let imageDecodeGate = ThumbnailDecodeGate(limit: 4, maxWaiters: 32)
    private let videoDecodeGate = ThumbnailDecodeGate(limit: 2, maxWaiters: 8)
    private let diskCache: ExternalDiskThumbnailCache
    private let imageGenerator: ImageGenerator
    private let videoGenerator: VideoGenerator

    init(
        diskCache: ExternalDiskThumbnailCache = .shared,
        imageGenerator: @escaping ImageGenerator = { item, pixels, allowEmbeddedThumbnail in
            ExternalImagePipeline.thumbnail(
                url: item.url,
                requestedPixelSize: pixels,
                preferEmbedded: allowEmbeddedThumbnail
            )
        },
        videoGenerator: @escaping VideoGenerator = { item, pixels in
            await ExternalThumbnailService.videoThumbnail(url: item.url, pixelSize: pixels)
        }
    ) {
        self.diskCache = diskCache
        self.imageGenerator = imageGenerator
        self.videoGenerator = videoGenerator
        cache.countLimit = 900
        cache.totalCostLimit = 256 * 1024 * 1024
        cache.delegate = cacheDelegate
        cacheDelegate.onEviction = { [weak self] in
            Task { @MainActor in
                self?.stats.evictions += 1
            }
        }
        installMemoryPressureHandler()
    }

    func image(
        for item: ExternalMediaItem,
        maxPixelSize: CGFloat,
        allowEmbeddedThumbnail: Bool = true,
        sizing _: ExternalThumbnailSizing = .longestEdge,
        priority: ExternalThumbnailRequestPriority = .visible,
        diskLookupPolicy: ExternalDiskThumbnailLookupPolicy = .exactLargerAndSmaller,
        allowSmallerMemoryHit: Bool = true
    ) async -> NSImage? {
        let identity = cacheIdentity(for: item, pixelSize: ThumbnailTier.fitting(maxPixelSize).pixels)
        let pixels = identity.tier.pixels
        let cacheKey = identity.cacheKey
        let mediaKey = identity.mediaKey
        if let cached = cachedThumbnail(
            for: item,
            pixelSize: pixels,
            recordsMiss: true,
            allowSmallerHit: allowSmallerMemoryHit
        ) {
            ExternalMediaScrollDiagnostics.shared.recordMemoryHit()
            return cached.image
        }
        if item.mediaType == .video,
           let cooldownUntil = videoFailureCooldownUntil[mediaKey],
           cooldownUntil > Date() {
            return nil
        }
        if let request = requests[cacheKey] {
            request.subscribers += 1
            await diskCache.recordCoalescedRequest()
            ExternalMediaScrollDiagnostics.shared.recordSharedReuse()
            return await waitForRequest(request, cacheKey: cacheKey).image
        }
        guard canCreateRequest(priority: priority) else { return nil }

        ExternalMediaScrollDiagnostics.shared.recordRequest(priority: priority)
        let requestID = UUID()
        let diskKey = ExternalDiskThumbnailKey(item: item, tier: identity.tier)
        let task = Task<LoadResult, Never>(priority: priority.taskPriority) { [diskCache, imageDecodeGate, videoDecodeGate, imageGenerator, videoGenerator] in
            if let diskRead = await diskCache.cachedThumbnail(for: diskKey, policy: diskLookupPolicy) {
                await ExternalMediaScrollDiagnostics.shared.recordDiskHit()
                return LoadResult(
                    image: diskRead.image,
                    tier: diskRead.tier,
                    cameFromSource: false,
                    wasSmallerDiskHit: diskRead.match == .smaller
                )
            }

            let gate = item.mediaType == .video ? videoDecodeGate : imageDecodeGate
            let didAcquire = await gate.acquire()
            let queues = await Self.queueSnapshot(imageGate: imageDecodeGate, videoGate: videoDecodeGate)
            ExternalMediaStartupDiagnostics.shared.recordQueues(
                image: queues.image,
                video: queues.video
            )
            guard didAcquire else {
                return LoadResult(image: nil, tier: identity.tier, cameFromSource: false, wasSmallerDiskHit: false)
            }
            defer {
                Task {
                    await gate.release()
                    let queues = await Self.queueSnapshot(imageGate: imageDecodeGate, videoGate: videoDecodeGate)
                    ExternalMediaStartupDiagnostics.shared.recordQueues(
                        image: queues.image,
                        video: queues.video
                    )
                }
            }
            guard !Task.isCancelled else {
                return LoadResult(image: nil, tier: identity.tier, cameFromSource: false, wasSmallerDiskHit: false)
            }
            let decodeStart = ContinuousClock.now
            let result = await Task.detached(priority: priority.taskPriority) {
                switch item.mediaType {
                case .image, .livePhoto:
                    await diskCache.recordSourceImageDecode()
                    return await imageGenerator(item, pixels, allowEmbeddedThumbnail)
                case .video:
                    await diskCache.recordSourceVideoGeneration()
                    return await videoGenerator(item, pixels)
                }
            }.value
            let duration = decodeStart.duration(to: .now).gpMilliseconds
            ExternalMediaStartupDiagnostics.shared.recordDecodeCompleted(
                isVideo: item.mediaType == .video,
                milliseconds: item.mediaType == .video ? duration : nil,
                timedOut: item.mediaType == .video && result == nil && duration >= 2_400
            )
            return LoadResult(
                image: result,
                tier: identity.tier,
                cameFromSource: true,
                wasSmallerDiskHit: false
            )
        }
        let request = Request(
            id: requestID,
            itemURL: item.url.standardizedFileURL,
            task: task,
            subscribers: 1
        )
        requests[cacheKey] = request
        ExternalMediaStartupDiagnostics.shared.recordTaskCreated(active: requests.count)
        let result = await waitForRequest(request, cacheKey: cacheKey)
        if requests[cacheKey]?.id == requestID { requests[cacheKey] = nil }
        ExternalMediaStartupDiagnostics.shared.recordTaskFinished(active: requests.count)

        // Failed, placeholder and all-black results never poison the cache.
        let image = result.image
        if let image, !ExternalImagePipeline.isAllBlack(image) {
            store(image, mediaKey: mediaKey, tier: result.tier)
            if result.cameFromSource {
                stats.decodedRequests += 1
                await diskCache.store(image, for: diskKey)
            } else if result.wasSmallerDiskHit {
                scheduleDiskSupplement(
                    for: item,
                    maxPixelSize: maxPixelSize,
                    allowEmbeddedThumbnail: allowEmbeddedThumbnail,
                    priority: priority
                )
            }
        } else if item.mediaType == .video {
            videoFailureCooldownUntil[mediaKey] = Date().addingTimeInterval(30)
        }
        return image
    }

    func cachedImage(
        for item: ExternalMediaItem,
        maxPixelSize: CGFloat,
        sizing _: ExternalThumbnailSizing
    ) -> NSImage? {
        cachedThumbnail(
            for: item,
            pixelSize: ThumbnailTier.fitting(maxPixelSize).pixels,
            recordsMiss: true
        )?.image
    }

    func cachedThumbnail(
        for item: ExternalMediaItem,
        maxPixelSize: CGFloat,
        sizing _: ExternalThumbnailSizing
    ) -> CachedThumbnail? {
        cachedThumbnail(
            for: item,
            pixelSize: ThumbnailTier.fitting(maxPixelSize).pixels,
            recordsMiss: true
        )
    }

    func cancelImageRequest(
        for item: ExternalMediaItem,
        maxPixelSize: CGFloat,
        sizing _: ExternalThumbnailSizing
    ) {
        releaseSubscriber(
            for: cacheIdentity(for: item, pixelSize: ThumbnailTier.fitting(maxPixelSize).pixels).cacheKey
        )
    }

    func cancelImageRequests(for item: ExternalMediaItem) {
        let url = item.url.standardizedFileURL
        for key in requests.compactMap({ $0.value.itemURL == url ? $0.key : nil }) {
            releaseSubscriber(for: key)
        }
    }

    func cancelRequests(in folderURL: URL) {
        let path = folderURL.standardizedFileURL.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for key in requests.compactMap({ key, value in
            let candidate = value.itemURL.path
            return candidate == path || candidate.hasPrefix(prefix) ? key : nil
        }) {
            releaseSubscriber(for: key)
        }
    }

    func removeAllCachedImages() {
        requests.values.forEach { $0.task.cancel() }
        requests.removeAll()
        cache.removeAllObjects()
        recentThumbnails.removeAll()
    }

    func cacheStatistics() -> ExternalThumbnailCacheStats {
        stats.evictions = cacheDelegate.evictionCount
        return stats
    }

    func diskCacheStatistics() async -> ExternalDiskThumbnailStats {
        await diskCache.statistics()
    }

    func resetDiskCacheStatistics() async {
        await diskCache.resetStatistics()
    }

    func recentLRUStatistics() -> ExternalThumbnailLRUStats {
        recentThumbnails.statistics()
    }

    func resetCacheStatistics() {
        stats = ExternalThumbnailCacheStats(evictions: cacheDelegate.evictionCount)
    }

    func logCacheStatistics(context: String) {
        let snapshot = cacheStatistics()
        let lruSnapshot = recentLRUStatistics()
        PerformanceLogger.log(
            "thumbnail-cache",
            duration: .zero,
            details: "\(context) \(snapshot.summary) lruUniqueMedia=\(lruSnapshot.uniqueMediaCount) lruObjects=\(lruSnapshot.objectCount)"
        )
    }

    func debugCacheIdentity(for item: ExternalMediaItem, maxPixelSize: CGFloat) -> ExternalThumbnailCacheIdentity {
        cacheIdentity(for: item, pixelSize: ThumbnailTier.fitting(maxPixelSize).pixels)
    }

    func runReturnVisitRegressionProbe(items: [ExternalMediaItem], visibleCount: Int = 48) async -> ExternalThumbnailRegressionResult {
        resetCacheStatistics()
        let firstPass = Array(items.prefix(visibleCount * 6))
        for item in firstPass {
            _ = await image(
                for: item,
                maxPixelSize: CGFloat(ThumbnailTier.preview.pixels),
                allowEmbeddedThumbnail: true
            )
        }

        let afterFirstPass = cacheStatistics()
        let returnItems = Array(firstPass.prefix(visibleCount * 3))
        resetCacheStatistics()
        var immediateImages = 0
        for item in returnItems {
            if cachedThumbnail(
                for: item,
                maxPixelSize: CGFloat(ThumbnailTier.large.pixels),
                sizing: .longestEdge
            ) != nil {
                immediateImages += 1
            }
        }
        let afterReturnLookup = cacheStatistics()
        for item in returnItems {
            if cachedThumbnail(
                for: item,
                maxPixelSize: CGFloat(ThumbnailTier.large.pixels),
                sizing: .longestEdge
            ) == nil {
                _ = await image(
                    for: item,
                    maxPixelSize: CGFloat(ThumbnailTier.preview.pixels),
                    allowEmbeddedThumbnail: true
                )
            }
        }
        let afterReturnPass = cacheStatistics()
        return ExternalThumbnailRegressionResult(
            firstPassDecodedRequests: afterFirstPass.decodedRequests,
            returnPassDecodedRequests: afterReturnPass.decodedRequests,
            returnPassMisses: afterReturnLookup.misses,
            returnPassImmediateImages: immediateImages,
            returnPassTotalImages: returnItems.count,
            stats: afterReturnPass
        )
    }

    func videoDuration(for item: ExternalMediaItem) async -> TimeInterval? {
        guard item.mediaType == .video else { return item.duration }
        let cacheKey = metadataKey(for: item)
        if let cached = durationCache[cacheKey] { return cached }
        let asset = AVURLAsset(url: item.url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        durationCache[cacheKey] = seconds
        return seconds
    }

    /// Required identity: stable media ID + source version + requested tier.
    private func cacheIdentity(for item: ExternalMediaItem, pixelSize: Int) -> ExternalThumbnailCacheIdentity {
        ExternalThumbnailCacheIdentity(
            mediaKey: mediaKey(for: item),
            tier: ThumbnailTier.fitting(CGFloat(pixelSize))
        )
    }

    private func mediaKey(for item: ExternalMediaItem) -> String {
        [
            item.stableMediaID,
            "mtimeNs=\(modificationNanoseconds(item.modificationDate))",
            "size=\(item.fileSize ?? -1)",
            "kind=\(item.mediaType.rawValue)",
            "rendering=\(ExternalDiskThumbnailKey.renderingVersion)"
        ].joined(separator: "#")
    }

    private func modificationNanoseconds(_ date: Date?) -> Int64 {
        guard let date else { return 0 }
        return Int64((date.timeIntervalSinceReferenceDate * 1_000_000_000).rounded())
    }

    private func cachedThumbnail(
        for item: ExternalMediaItem,
        pixelSize: Int,
        recordsMiss: Bool,
        allowSmallerHit: Bool = true
    ) -> CachedThumbnail? {
        let requestedTier = ThumbnailTier.fitting(CGFloat(pixelSize))
        let mediaKey = mediaKey(for: item)
        if let cached = recentThumbnails.image(
            forMediaKey: mediaKey,
            requestedTier: requestedTier,
            allowSmallerHit: allowSmallerHit
        ) {
            switch cached.match {
            case .exact:
                stats.exactHits += 1
            case .larger:
                stats.largerTierHits += 1
            case .smaller:
                stats.smallerTierHits += 1
            }
            return CachedThumbnail(
                image: cached.image,
                tier: cached.tier,
                satisfiesRequestedTier: cached.tier.pixels >= requestedTier.pixels
            )
        }

        let exactIdentity = cacheIdentity(for: item, pixelSize: requestedTier.pixels)
        if let image = cachedImage(forKey: exactIdentity.cacheKey, mediaKey: mediaKey, tier: requestedTier) {
            stats.exactHits += 1
            return CachedThumbnail(image: image, tier: requestedTier, satisfiesRequestedTier: true)
        }

        for tier in ThumbnailTier.allCases where tier.pixels > requestedTier.pixels {
            let candidateKey = cacheIdentity(for: item, pixelSize: tier.pixels).cacheKey
            if let image = cachedImage(forKey: candidateKey, mediaKey: mediaKey, tier: tier) {
                stats.largerTierHits += 1
                return CachedThumbnail(image: image, tier: tier, satisfiesRequestedTier: true)
            }
        }

        if allowSmallerHit {
            for tier in ThumbnailTier.allCases.reversed() where tier.pixels < requestedTier.pixels {
                let candidateKey = cacheIdentity(for: item, pixelSize: tier.pixels).cacheKey
                if let image = cachedImage(forKey: candidateKey, mediaKey: mediaKey, tier: tier) {
                    stats.smallerTierHits += 1
                    return CachedThumbnail(image: image, tier: tier, satisfiesRequestedTier: false)
                }
            }
        }

        if recordsMiss { stats.misses += 1 }
        return nil
    }

    private func cachedImage(forKey key: String, mediaKey: String, tier: ThumbnailTier) -> NSImage? {
        guard let image = cache.object(forKey: key as NSString) else { return nil }
        recentThumbnails.set(image, forMediaKey: mediaKey, tier: tier, cost: imageCost(image))
        return image
    }

    private func store(_ image: NSImage, for key: String) {
        let cost = imageCost(image)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        guard let parsed = parseCacheKey(key) else { return }
        recentThumbnails.set(image, forMediaKey: parsed.mediaKey, tier: parsed.tier, cost: cost)
    }

    private func store(_ image: NSImage, mediaKey: String, tier: ThumbnailTier) {
        let identity = ExternalThumbnailCacheIdentity(mediaKey: mediaKey, tier: tier)
        let cost = imageCost(image)
        cache.setObject(image, forKey: identity.cacheKey as NSString, cost: cost)
        recentThumbnails.set(image, forMediaKey: mediaKey, tier: tier, cost: cost)
    }

    private func scheduleDiskSupplement(
        for item: ExternalMediaItem,
        maxPixelSize: CGFloat,
        allowEmbeddedThumbnail: Bool,
        priority: ExternalThumbnailRequestPriority
    ) {
        Task { @MainActor in
            _ = await self.image(
                for: item,
                maxPixelSize: maxPixelSize,
                allowEmbeddedThumbnail: allowEmbeddedThumbnail,
                priority: priority == .visible ? .finalUpgrade : priority,
                diskLookupPolicy: .exactAndLarger,
                allowSmallerMemoryHit: false
            )
        }
    }

    private func imageCost(_ image: NSImage) -> Int {
        max(1, image.representations.map { $0.pixelsWide * $0.pixelsHigh * 4 }.max() ?? 1)
    }

    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            let event = source?.data ?? []
            let capacity = event.contains(.critical) ? 120 : 250
            self.recentThumbnails.trim(to: capacity)
        }
        source.resume()
        memoryPressureSource = source
    }

    private func waitForRequest(_ request: Request, cacheKey: String) async -> LoadResult {
        await withTaskCancellationHandler {
            await request.task.value
        } onCancel: {
            Task { @MainActor in
                self.releaseSubscriber(for: cacheKey)
            }
        }
    }

    private func releaseSubscriber(for cacheKey: String) {
        guard let request = requests[cacheKey] else { return }
        request.subscribers -= 1
        guard request.subscribers <= 0 else { return }
        requests.removeValue(forKey: cacheKey)
        request.task.cancel()
        Task { @MainActor in
            ExternalMediaStartupDiagnostics.shared.recordCancel()
            ExternalMediaScrollDiagnostics.shared.recordUnderlyingCancel()
            ExternalMediaStartupDiagnostics.shared.recordTaskFinished(active: requests.count)
        }
    }

    private func metadataKey(for item: ExternalMediaItem) -> String {
        mediaKey(for: item)
    }

    private func parseCacheKey(_ key: String) -> ExternalThumbnailCacheIdentity? {
        guard let range = key.range(of: "#tier=", options: .backwards),
              let pixels = Int(key[range.upperBound...]) else { return nil }
        return ExternalThumbnailCacheIdentity(
            mediaKey: String(key[..<range.lowerBound]),
            tier: ThumbnailTier.fitting(CGFloat(pixels))
        )
    }

    private func canCreateRequest(priority: ExternalThumbnailRequestPriority) -> Bool {
        let limit: Int
        switch priority {
        case .visible:
            limit = 48
        case .finalUpgrade:
            limit = 24
        case .preheat:
            limit = 12
        }
        return requests.count < limit
    }

    nonisolated private static func videoThumbnail(url: URL, pixelSize: Int) async -> NSImage? {
        await withTimeout(seconds: 2.5) {
            await videoThumbnailWithoutTimeout(url: url, pixelSize: pixelSize)
        }
    }

    nonisolated private static func videoThumbnailWithoutTimeout(url: URL, pixelSize: Int) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        let duration = (try? await generator.asset.load(.duration)).flatMap { duration -> Double? in
            guard duration.isNumeric else { return nil }
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds > 0 ? seconds : nil
        } ?? 0
        let candidates: [Double] = [
            0,
            0.1,
            duration > 0 ? min(max(duration * 0.03, 0.2), 1.5) : 0.2
        ]

        for seconds in candidates {
            guard !Task.isCancelled else { return nil }
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let result = try? await generator.image(at: time) else { continue }
            if !ExternalImagePipeline.isAllBlack(result.image) {
                return NSImage(cgImage: result.image, size: .zero)
            }
        }
        return nil
    }

    nonisolated private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    nonisolated private static func queueSnapshot(
        imageGate: ThumbnailDecodeGate,
        videoGate: ThumbnailDecodeGate
    ) async -> (image: Int, video: Int) {
        async let image = imageGate.waiterCount()
        async let video = videoGate.waiterCount()
        return await (image, video)
    }
}

private actor ThumbnailDecodeGate {
    private var permits: Int
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private let maxWaiters: Int

    init(limit: Int, maxWaiters: Int) {
        permits = max(1, limit)
        self.maxWaiters = max(0, maxWaiters)
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if permits > 0 { permits -= 1; return true }
        guard waiters.count < maxWaiters else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in waiters[id] = continuation }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if let (id, continuation) = waiters.first {
            waiters[id] = nil
            continuation.resume(returning: true)
        } else {
            permits += 1
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }

    func waiterCount() -> Int {
        waiters.count
    }
}

private final class ThumbnailCacheDelegate: NSObject, NSCacheDelegate {
    var evictionCount = 0
    var onEviction: (() -> Void)?

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        evictionCount += 1
        onEviction?()
    }
}

private final class RecentThumbnailLRU {
    enum TierMatch {
        case exact
        case larger
        case smaller
    }

    struct CachedEntry {
        let image: NSImage
        let tier: ThumbnailTier
        let match: TierMatch
    }

    private struct Entry {
        let image: NSImage
        let tier: ThumbnailTier
        let cost: Int
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var mediaKeysByRecency: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func image(
        forMediaKey mediaKey: String,
        requestedTier: ThumbnailTier,
        allowSmallerHit: Bool = true
    ) -> CachedEntry? {
        guard let entry = entries[mediaKey] else { return nil }
        guard allowSmallerHit || entry.tier.pixels >= requestedTier.pixels else { return nil }
        touch(mediaKey)
        let match: TierMatch
        if entry.tier == requestedTier {
            match = .exact
        } else if entry.tier.pixels > requestedTier.pixels {
            match = .larger
        } else {
            match = .smaller
        }
        return CachedEntry(image: entry.image, tier: entry.tier, match: match)
    }

    func set(_ image: NSImage, forMediaKey mediaKey: String, tier: ThumbnailTier, cost: Int) {
        if let existing = entries[mediaKey], existing.tier.pixels > tier.pixels {
            touch(mediaKey)
            return
        }
        entries[mediaKey] = Entry(image: image, tier: tier, cost: cost)
        touch(mediaKey)
        trim(to: capacity)
    }

    func remove(mediaKey: String) {
        entries.removeValue(forKey: mediaKey)
        mediaKeysByRecency.removeAll { $0 == mediaKey }
    }

    func removeAll() {
        entries.removeAll()
        mediaKeysByRecency.removeAll()
    }

    func trim(to newCapacity: Int) {
        let target = max(0, newCapacity)
        while mediaKeysByRecency.count > target, let oldest = mediaKeysByRecency.first {
            remove(mediaKey: oldest)
        }
    }

    func statistics() -> ExternalThumbnailLRUStats {
        ExternalThumbnailLRUStats(
            uniqueMediaCount: entries.count,
            objectCount: entries.count
        )
    }

    private func touch(_ mediaKey: String) {
        mediaKeysByRecency.removeAll { $0 == mediaKey }
        mediaKeysByRecency.append(mediaKey)
    }
}

/// FlowVision-inspired ImageIO pipeline, rewritten around GladPhotos' dynamic
/// pixel requests. It contains no view/layout policy.
enum ExternalImagePipeline {
    nonisolated static func thumbnail(
        url: URL,
        requestedPixelSize: Int,
        preferEmbedded: Bool
    ) -> NSImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) else { return nil }

        let index = CGImageSourceGetPrimaryImageIndex(source)
        let pixels = min(1_600, max(1, requestedPixelSize))
        let common: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]

        // HEIC/HEIF/RAW may carry a useful embedded preview. If ImageIO returns
        // a corrupt black preview, immediately regenerate from the primary image.
        if preferEmbedded, prefersEmbeddedPreview(url) {
            var options = common
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            if let candidate = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
               !isAllBlack(candidate), !Task.isCancelled {
                return NSImage(cgImage: candidate, size: .zero)
            }
        }

        var options = common
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              !Task.isCancelled else { return nil }
        // CGImage preserves PNG alpha; NSImage is constructed without flattening.
        return NSImage(cgImage: image, size: .zero)
    }

    nonisolated static func isAllBlack(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }
        return isAllBlack(cgImage)
    }

    nonisolated static func isAllBlack(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let context = CGContext(
            data: &pixels, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 8 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        return stride(from: 0, to: pixels.count, by: 4).allSatisfy {
            pixels[$0] <= 2 && pixels[$0 + 1] <= 2 && pixels[$0 + 2] <= 2
        }
    }

    nonisolated private static func prefersEmbeddedPreview(_ url: URL) -> Bool {
        ["heic", "heif", "dng", "raw", "cr2", "cr3", "nef", "arw", "raf"]
            .contains(url.pathExtension.lowercased())
    }
}

nonisolated private extension Duration {
    var gpMilliseconds: Double {
        Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
    }
}
