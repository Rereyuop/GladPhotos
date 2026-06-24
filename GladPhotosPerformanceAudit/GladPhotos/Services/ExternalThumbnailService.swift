import AVFoundation
import AppKit
import ImageIO

enum ExternalThumbnailSizing: String, Sendable {
    case longestEdge
    case displayWidth
    case squareCell
}

/// Visible-media thumbnail scheduler. The cache and in-flight table live on the
/// main actor; decoding itself is bounded and runs off actor.
@MainActor
final class ExternalThumbnailService {
    private struct Request {
        let id: UUID
        let itemURL: URL
        let task: Task<NSImage?, Never>
    }

    private let cache = NSCache<NSString, NSImage>()
    private var requests: [String: Request] = [:]
    private var durationCache: [String: TimeInterval] = [:]
    private let visibleDecodeGate = ThumbnailDecodeGate(limit: 4)

    init() {
        cache.countLimit = 500
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    func image(
        for item: ExternalMediaItem,
        maxPixelSize: CGFloat,
        allowEmbeddedThumbnail: Bool = true,
        sizing _: ExternalThumbnailSizing = .longestEdge
    ) async -> NSImage? {
        let pixels = min(1_600, max(1, Int(maxPixelSize.rounded(.up))))
        let cacheKey = key(for: item, pixelSize: pixels)
        if let cached = cache.object(forKey: cacheKey as NSString) { return cached }
        if let request = requests[cacheKey] { return await request.task.value }

        let requestID = UUID()
        let task = Task<NSImage?, Never>(priority: .userInitiated) {
            guard await visibleDecodeGate.acquire() else { return nil }
            defer { Task { await visibleDecodeGate.release() } }
            guard !Task.isCancelled else { return nil }
            let start = ContinuousClock.now
            let result = await Task.detached(priority: .userInitiated) {
                switch item.mediaType {
                case .image, .livePhoto:
                    return ExternalImagePipeline.thumbnail(
                        url: item.url,
                        requestedPixelSize: pixels,
                        preferEmbedded: allowEmbeddedThumbnail
                    )
                case .video:
                    return await Self.videoThumbnail(url: item.url, pixelSize: pixels)
                }
            }.value
            PerformanceLogger.log(
                "thumbnail", duration: start.duration(to: .now),
                details: "pixels=\(pixels) type=\(item.mediaType.rawValue)"
            )
            return result
        }
        requests[cacheKey] = Request(id: requestID, itemURL: item.url.standardizedFileURL, task: task)
        let image = await task.value
        if requests[cacheKey]?.id == requestID { requests[cacheKey] = nil }

        // Failed, placeholder and all-black results never poison the cache.
        if let image, !ExternalImagePipeline.isAllBlack(image) {
            let cost = max(1, image.representations.map { $0.pixelsWide * $0.pixelsHigh * 4 }.max() ?? 1)
            cache.setObject(image, forKey: cacheKey as NSString, cost: cost)
        }
        return image
    }

    func cachedImage(
        for item: ExternalMediaItem,
        maxPixelSize: CGFloat,
        sizing _: ExternalThumbnailSizing
    ) -> NSImage? {
        cache.object(forKey: key(
            for: item,
            pixelSize: min(1_600, max(1, Int(maxPixelSize.rounded(.up))))
        ) as NSString)
    }

    func cancelImageRequest(
        for item: ExternalMediaItem,
        maxPixelSize: CGFloat,
        sizing _: ExternalThumbnailSizing
    ) {
        let cacheKey = key(
            for: item,
            pixelSize: min(1_600, max(1, Int(maxPixelSize.rounded(.up))))
        )
        requests.removeValue(forKey: cacheKey)?.task.cancel()
    }

    func cancelImageRequests(for item: ExternalMediaItem) {
        let url = item.url.standardizedFileURL
        for key in requests.compactMap({ $0.value.itemURL == url ? $0.key : nil }) {
            requests.removeValue(forKey: key)?.task.cancel()
        }
    }

    func cancelRequests(in folderURL: URL) {
        let path = folderURL.standardizedFileURL.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for key in requests.compactMap({ key, value in
            let candidate = value.itemURL.path
            return candidate == path || candidate.hasPrefix(prefix) ? key : nil
        }) {
            requests.removeValue(forKey: key)?.task.cancel()
        }
    }

    func removeAllCachedImages() {
        requests.values.forEach { $0.task.cancel() }
        requests.removeAll()
        cache.removeAllObjects()
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

    /// Required identity: file URL + modification date + requested pixels.
    private func key(for item: ExternalMediaItem, pixelSize: Int) -> String {
        "\(item.url.standardizedFileURL.path)#\(item.modificationDate?.timeIntervalSinceReferenceDate ?? 0)#\(pixelSize)"
    }

    private func metadataKey(for item: ExternalMediaItem) -> String {
        "\(item.url.standardizedFileURL.path)#\(item.modificationDate?.timeIntervalSinceReferenceDate ?? 0)"
    }

    nonisolated private static func videoThumbnail(url: URL, pixelSize: Int) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        guard let result = try? await generator.image(at: .zero), !Task.isCancelled else { return nil }
        return NSImage(cgImage: result.image, size: .zero)
    }
}

private actor ThumbnailDecodeGate {
    private var permits: Int
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(limit: Int) { permits = max(1, limit) }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if permits > 0 { permits -= 1; return true }
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
