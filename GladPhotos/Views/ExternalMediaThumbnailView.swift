import AppKit
import SwiftUI

struct ExternalMediaThumbnailView: View {
    let item: ExternalMediaItem
    let thumbnailService: ExternalThumbnailService
    let displayMode: PhotoGridDisplayMode
    let thumbnailWidth: CGFloat
    let showsMediaInfo: Bool
    let allowsFinalThumbnail: Bool
    let finalLoadID: UUID

    @Environment(\.displayScale) private var displayScale
    @State private var previewImage: NSImage?
    @State private var finalImage: NSImage?
    @State private var displayedMediaKey: String?
    @State private var didFinishPreview = false
    @State private var finalLoadFailed = false
    @State private var renderedWidth: CGFloat = 0
    @State private var renderedTier: ThumbnailTier = .preview
    @State private var isVisible = false
    @State private var loadTask: Task<Void, Never>?
    @State private var activeRequest = ThumbnailRequestIdentity.empty
    @State private var loadedDuration: TimeInterval?
    @State private var spinnerReason: ExternalThumbnailSpinnerReason?

    init(
        item: ExternalMediaItem,
        thumbnailService: ExternalThumbnailService,
        displayMode: PhotoGridDisplayMode,
        thumbnailWidth: CGFloat,
        showsMediaInfo: Bool,
        allowsFinalThumbnail: Bool,
        finalLoadID: UUID
    ) {
        self.item = item
        self.thumbnailService = thumbnailService
        self.displayMode = displayMode
        self.thumbnailWidth = thumbnailWidth
        self.showsMediaInfo = showsMediaInfo
        self.allowsFinalThumbnail = allowsFinalThumbnail
        self.finalLoadID = finalLoadID
        ExternalMediaStartupDiagnostics.shared.recordCellCreated()

        let cached = thumbnailService.cachedThumbnail(
            for: item,
            maxPixelSize: CGFloat(ThumbnailTier.maximum.pixels),
            sizing: .longestEdge
        )
        let initialMediaKey = cached == nil
            ? nil
            : thumbnailService.debugCacheIdentity(
                for: item,
                maxPixelSize: CGFloat(ThumbnailTier.maximum.pixels)
            ).mediaKey
        _previewImage = State(initialValue: cached?.satisfiesRequestedTier == false ? cached?.image : nil)
        _finalImage = State(initialValue: cached?.satisfiesRequestedTier == true ? cached?.image : nil)
        _displayedMediaKey = State(initialValue: initialMediaKey)
        _didFinishPreview = State(initialValue: cached != nil)
        _spinnerReason = State(initialValue: cached == nil ? .noCachedImage : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            thumbnail

            if showsMediaInfo {
                mediaInfo
            }
        }
        .contentShape(Rectangle())
        .help(item.filename)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - renderedWidth) >= 1 else { return }
            let oldTier = renderedTier
            renderedWidth = width
            renderedTier = requestedTier
            debugTrace("geometry width=\(Int(width.rounded())) tier=\(renderedTier.rawValue)")
            if isVisible, renderedTier != oldTier {
                debugTrace("geometry tier changed \(oldTier.rawValue)->\(renderedTier.rawValue)")
                startLoading(trigger: .geometryTierChanged)
            }
        }
        // Only visible cells own UI writes; cancellation releases this subscriber
        // and the shared service keeps decoding while other consumers remain.
        .onAppear {
            isVisible = true
            ExternalMediaStartupDiagnostics.shared.recordOnAppear()
            renderedTier = requestedTier
            debugTrace("onAppear width=\(Int(renderedWidth.rounded())) tier=\(renderedTier.rawValue)")
            if renderedWidth > 0 { startLoading(trigger: .onAppear) }
        }
        .onDisappear {
            isVisible = false
            debugTrace("onDisappear")
            cancelLoading()
        }
        .onChange(of: requestID) {
            debugTrace("task id changed requestID=\(requestID)")
            if isVisible, renderedWidth > 0 { startLoading(trigger: .taskIDChanged) }
        }
        .onChange(of: finalLoadID) {
            guard allowsFinalThumbnail, isVisible, renderedWidth > 0 else { return }
            debugTrace("scroll/finalLoadID changed finalImage=\(finalImage != nil) finalLoadFailed=\(finalLoadFailed)")
            if finalImage == nil || finalLoadFailed { startLoading(trigger: .scrollingStateChanged) }
        }
    }

    private var requestID: String {
        let identity = thumbnailService.debugCacheIdentity(for: item, maxPixelSize: CGFloat(requestedTier.pixels))
        return "\(identity.mediaKey)#mode=\(displayMode.title)#scale=\(displayScale)#tier=\(requestedTier.rawValue)#final=\(allowsFinalThumbnail)"
    }

    private var requestedTier: ThumbnailTier {
        let ratio = max(0.01, item.pixelAspectRatio ?? 1)
        return ThumbnailTier.fitting(max(renderedWidth, renderedWidth / ratio) * displayScale)
    }

    private var image: NSImage? {
        finalImage ?? previewImage
    }

    private var mediaKey: String {
        thumbnailService.debugCacheIdentity(for: item, maxPixelSize: CGFloat(requestedTier.pixels)).mediaKey
    }

    private func startLoading(trigger: ExternalThumbnailLoadTrigger) {
        debugTrace("startLoading trigger=\(trigger.rawValue) width=\(Int(renderedWidth.rounded())) requestedTier=\(requestedTier.rawValue)")
        cancelLoading()
        let identity = ThumbnailRequestIdentity(mediaID: item.id, requestID: UUID())
        activeRequest = identity
        debugTrace("task id set \(identity.requestID)")
        if let displayedMediaKey, displayedMediaKey != mediaKey {
            debugTrace("displayedImage cleared reason=mediaChanged old=\(displayedMediaKey) new=\(mediaKey)")
            previewImage = nil
            finalImage = nil
            didFinishPreview = false
            spinnerReason = .stateWasCleared
        }
        loadedDuration = nil
        finalLoadFailed = false
        let finalTier = requestedTier
        renderedTier = finalTier

        if let cached = thumbnailService.cachedThumbnail(
            for: item,
            maxPixelSize: CGFloat(finalTier.pixels),
            sizing: .longestEdge
        ) {
            debugTrace("sync cache hit tier=\(cached.tier.rawValue) satisfies=\(cached.satisfiesRequestedTier)")
            if cached.satisfiesRequestedTier {
                finalImage = cached.image
                debugTrace("displayedImage set source=sync-final tier=\(cached.tier.rawValue)")
            } else {
                previewImage = cached.image
                debugTrace("displayedImage set source=sync-preview tier=\(cached.tier.rawValue)")
            }
            displayedMediaKey = mediaKey
            spinnerReason = nil
            didFinishPreview = true
            if cached.satisfiesRequestedTier, item.mediaType != .video { return }
        } else if image == nil {
            debugTrace("sync cache miss reason=\(spinnerReasonDescription(.noCachedImage))")
            didFinishPreview = false
            spinnerReason = .noCachedImage
        } else {
            debugTrace("sync cache miss but keeping existing displayedImage")
        }

        loadTask = Task {
            let preview: NSImage?
            if let image {
                preview = image
            } else {
                debugTrace("preview request start tier=\(ThumbnailTier.preview.rawValue)")
                await ExternalMediaStartupDiagnostics.shared.recordPreviewRequest()
                preview = await thumbnailService.image(
                    for: item,
                    maxPixelSize: CGFloat(ThumbnailTier.preview.pixels),
                    allowEmbeddedThumbnail: true,
                    sizing: .longestEdge,
                    priority: .visible
                )
            }
            guard !Task.isCancelled,
                  activeRequest == identity,
                  item.id == identity.mediaID,
                  isVisible else {
                debugTrace("preview request cancelled task=\(identity.requestID)")
                if image == nil { spinnerReason = .requestCancelled }
                return
            }

            if let preview {
                previewImage = preview
                displayedMediaKey = mediaKey
                spinnerReason = nil
                debugTrace("displayedImage set source=preview-request")
            }
            didFinishPreview = true
            debugTrace("preview request complete hasImage=\(preview != nil)")

            guard allowsFinalThumbnail else {
                await loadDurationIfNeeded(identity: identity)
                return
            }

            debugTrace("final request start tier=\(finalTier.rawValue)")
            await ExternalMediaStartupDiagnostics.shared.recordFinalRequest()
            let loadedImage = finalTier != .preview
                ? await thumbnailService.image(
                    for: item,
                    maxPixelSize: CGFloat(finalTier.pixels),
                    allowEmbeddedThumbnail: false,
                    sizing: .longestEdge,
                    priority: .finalUpgrade
                )
                : preview
            guard !Task.isCancelled,
                  activeRequest == identity,
                  item.id == identity.mediaID,
                  isVisible else {
                debugTrace("final request cancelled task=\(identity.requestID)")
                ExternalMediaScrollDiagnostics.shared.recordDiscardedFinal()
                return
            }

            if let loadedImage {
                finalImage = loadedImage
                spinnerReason = nil
                debugTrace("displayedImage set source=final-request tier=\(finalTier.rawValue)")
            } else if preview != nil {
                finalLoadFailed = true
            }
            displayedMediaKey = mediaKey
            debugTrace("final request complete hasImage=\(loadedImage != nil)")
            await loadDurationIfNeeded(identity: identity)
        }
    }

    private func cancelLoading() {
        if loadTask != nil { debugTrace("request cancelled task=\(activeRequest.requestID)") }
        activeRequest = .empty
        loadTask?.cancel()
        loadTask = nil
    }

    private func loadDurationIfNeeded(identity: ThumbnailRequestIdentity) async {
        guard item.mediaType == .video else { return }
        let duration = await thumbnailService.videoDuration(for: item)
        guard !Task.isCancelled,
              activeRequest == identity,
              item.id == identity.mediaID,
              isVisible else { return }
        loadedDuration = duration
    }

    private var thumbnail: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: displayMode == .square ? .fill : .fit)
            } else if didFinishPreview {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityIdentifier("ExternalMediaThumbnailSpinner")
                    .onAppear {
                        let reason = spinnerReason ?? .noCachedImage
                        spinnerReason = reason
                        debugTrace("spinner appear reason=\(spinnerReasonDescription(reason))")
                    }
            }

            if item.mediaType == .video {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "video.fill")
                            if let duration = item.duration ?? loadedDuration {
                                Text(durationText(duration)).monospacedDigit()
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(6)
                    }
                }
            }

            if item.isLivePhoto {
                livePhotoBadge
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(aspectRatio, contentMode: displayMode == .square ? .fill : .fit)
        .background(.quaternary.opacity(displayMode == .square ? 0 : 0.35))
        .clipped()
    }

    private var livePhotoBadge: some View {
        VStack {
            HStack {
                Image(systemName: "livephoto")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .padding(.leading, 6)
                    .padding(.top, 6)
                Spacer()
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var mediaInfo: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.displayDate?.formatted(
                .dateTime
                    .day()
                    .hour(.twoDigits(amPM: .omitted))
                    .minute(.twoDigits)
                    .locale(.gladPhotosChinese)
            ) ?? "时间未知")

            if let fileSize = item.fileSize {
                Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
            } else {
                Text("大小不可用")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var aspectRatio: CGFloat {
        guard displayMode == .originalRatio else { return 1 }
        if let ratio = item.pixelAspectRatio { return ratio }
        guard let image, image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum ExternalThumbnailSpinnerReason: String, Sendable {
    case noCachedImage
    case cacheKeyMismatch
    case stateWasCleared
    case requestCancelled
    case memoryEvicted
}

private enum ExternalThumbnailLoadTrigger: String {
    case onAppear
    case taskIDChanged
    case geometryTierChanged
    case scrollingStateChanged
}

private struct ThumbnailRequestIdentity: Equatable {
    let mediaID: ExternalMediaItem.ID
    let requestID: UUID

    static let empty = ThumbnailRequestIdentity(
        mediaID: "",
        requestID: UUID()
    )
}

private extension ExternalMediaThumbnailView {
    func debugTrace(_ message: String) {
        #if DEBUG
        let target = ProcessInfo.processInfo.environment["GLADPHOTOS_THUMBNAIL_DEBUG_MEDIA_ID"]
            ?? UserDefaults.standard.string(forKey: "ExternalMediaThumbnailDebugMediaID")
        guard let target, !target.isEmpty else { return }
        let candidates = [
            item.id,
            item.url.absoluteString,
            item.url.path,
            mediaKey
        ]
        guard candidates.contains(target) || candidates.contains(where: { $0.hasSuffix(target) }) else { return }
        print("[ExternalMediaThumbnailView] \(item.filename) \(message)")
        #endif
    }

    func spinnerReasonDescription(_ reason: ExternalThumbnailSpinnerReason) -> String {
        switch reason {
        case .noCachedImage:
            return "noCachedImage"
        case .cacheKeyMismatch:
            return "cacheKeyMismatch"
        case .stateWasCleared:
            return "stateWasCleared"
        case .requestCancelled:
            return "requestCancelled"
        case .memoryEvicted:
            return "memoryEvicted"
        }
    }
}
