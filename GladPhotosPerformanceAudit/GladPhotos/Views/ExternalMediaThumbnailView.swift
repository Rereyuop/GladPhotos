import AppKit
import SwiftUI

struct ExternalMediaThumbnailView: View {
    let item: ExternalMediaItem
    let thumbnailService: ExternalThumbnailService
    let displayMode: PhotoGridDisplayMode
    let thumbnailWidth: CGFloat
    let showsMediaInfo: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var displayedMediaID: URL?
    @State private var didFinishLoading = false
    @State private var renderedWidth: CGFloat = 0
    @State private var isVisible = false
    @State private var loadTask: Task<Void, Never>?
    @State private var activeRequest = ThumbnailRequestIdentity.empty
    @State private var activePixelSize: CGFloat = 0
    @State private var loadedDuration: TimeInterval?

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
            renderedWidth = width
            if isVisible { startLoading() }
        }
        // Design reference: netdcy/FlowVision CustomCollectionViewItem.swift
        // @ d8a725c. SwiftUI adaptation: only visible LazyVGrid cells own work;
        // disappearance/reuse cancels it and a token blocks stale async writes.
        .onAppear {
            isVisible = true
            if renderedWidth > 0 { startLoading() }
        }
        .onDisappear {
            isVisible = false
            cancelLoading()
        }
        .onChange(of: requestID) {
            if isVisible, renderedWidth > 0 { startLoading() }
        }
    }

    private var requestID: String {
        "\(item.url.path)#\(displayMode.title)#\(requestedPixelSize)"
    }

    private var requestedPixelSize: CGFloat {
        let ratio = max(0.01, item.pixelAspectRatio ?? 1)
        return min(1_600, max(renderedWidth, renderedWidth / ratio) * displayScale)
    }

    private func startLoading() {
        cancelLoading()
        let identity = ThumbnailRequestIdentity(mediaID: item.id, requestID: UUID())
        activeRequest = identity
        if displayedMediaID != item.id { image = nil }
        loadedDuration = nil
        didFinishLoading = false
        let pixelSize = requestedPixelSize
        activePixelSize = pixelSize
        if let cached = thumbnailService.cachedImage(
            for: item,
            maxPixelSize: pixelSize,
            sizing: .longestEdge
        ) {
            image = cached
            displayedMediaID = item.id
            didFinishLoading = true
            if item.mediaType != .video { return }
        }
        loadTask = Task {
            let previewPixels = min(pixelSize, 320)
            let preview: NSImage?
            if let image {
                preview = image
            } else {
                preview = await thumbnailService.image(
                    for: item,
                    maxPixelSize: previewPixels,
                    allowEmbeddedThumbnail: true,
                    sizing: .longestEdge
                )
            }
            guard !Task.isCancelled, activeRequest == identity,
                  item.id == identity.mediaID, isVisible else { return }
            if let preview {
                image = preview
                displayedMediaID = item.id
            }

            let loadedImage = pixelSize > previewPixels * 1.15
                ? await thumbnailService.image(
                    for: item,
                    maxPixelSize: pixelSize,
                    allowEmbeddedThumbnail: false,
                    sizing: .longestEdge
                )
                : preview
            guard !Task.isCancelled,
                  activeRequest == identity,
                  item.id == identity.mediaID,
                  isVisible else { return }
            if let loadedImage { image = loadedImage }
            displayedMediaID = item.id
            didFinishLoading = image != nil
            if item.mediaType == .video {
                let duration = await thumbnailService.videoDuration(for: item)
                guard !Task.isCancelled,
                      activeRequest == identity,
                      item.id == identity.mediaID,
                      isVisible else { return }
                loadedDuration = duration
            }
        }
    }

    private func cancelLoading() {
        activeRequest = .empty
        loadTask?.cancel()
        loadTask = nil
        thumbnailService.cancelImageRequests(for: item)
        if activePixelSize > 0 {
            thumbnailService.cancelImageRequest(
                for: item,
                maxPixelSize: activePixelSize,
                sizing: .longestEdge
            )
            activePixelSize = 0
        }
    }

    private var thumbnailSizing: ExternalThumbnailSizing {
        displayMode == .square ? .squareCell : .displayWidth
    }

    private var thumbnail: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: displayMode == .square ? .fill : .fit)
            } else if didFinishLoading {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
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

private struct ThumbnailRequestIdentity: Equatable {
    let mediaID: URL
    let requestID: UUID

    static let empty = ThumbnailRequestIdentity(
        mediaID: URL(fileURLWithPath: "/dev/null"),
        requestID: UUID()
    )
}
