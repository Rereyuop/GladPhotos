import Photos
import SwiftUI

enum PhotoGridDisplayMode {
    case square
    case originalRatio

    var title: String {
        switch self {
        case .square:
            return "正方形"
        case .originalRatio:
            return "原比例"
        }
    }
}

struct PhotoThumbnailView: View {
    let item: PhotoAssetItem
    let imageService: PhotoImageService
    let displayMode: PhotoGridDisplayMode
    let thumbnailWidth: CGFloat
    let isSelected: Bool
    let showsSelectionState: Bool
    let showsPhotoInfo: Bool

    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?
    @State private var requestedIdentifier: String?
    @State private var resourceSizeRequestID: UUID?
    @State private var resourceSize: Int64?
    @State private var isResourceSizeUnavailable = false
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            thumbnail

            if showsPhotoInfo {
                photoInfo
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            isVisible = true
            requestImage()
            requestResourceSizeIfNeeded()
        }
        .onDisappear {
            isVisible = false
            cancelRequest()
            cancelResourceSizeRequest()
        }
        .onChange(of: item.localIdentifier) {
            cancelRequest()
            cancelResourceSizeRequest()
            image = nil
            resourceSize = nil
            isResourceSizeUnavailable = false
            requestImage()
            requestResourceSizeIfNeeded()
        }
        .onChange(of: showsPhotoInfo) {
            if showsPhotoInfo {
                requestResourceSizeIfNeeded()
            } else {
                cancelResourceSizeRequest()
                resourceSize = nil
                isResourceSizeUnavailable = false
            }
        }
        .onChange(of: displayMode) {
            cancelRequest()
            image = nil
            requestImage()
        }
        .onChange(of: thumbnailWidth) {
            cancelRequest()
            requestImage()
        }
    }

    private var thumbnail: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: displayMode == .square ? .fill : .fit)
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }

            selectionOverlay
                .opacity(showsSelectionState ? 1 : 0)

            if item.asset.mediaSubtypes.contains(.photoLive) {
                livePhotoBadge
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(aspectRatio, contentMode: displayMode == .square ? .fill : .fit)
        .background(.quaternary.opacity(displayMode == .square ? 0 : 0.35))
        .clipped()
    }

    private var photoInfo: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.asset.creationDate?.formatted(
                .dateTime
                    .day()
                    .hour(.twoDigits(amPM: .omitted))
                    .minute(.twoDigits)
                    .locale(.gladPhotosChinese)
            ) ?? "时间未知")

            Text(resourceSizeText)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var resourceSizeText: String {
        if let resourceSize {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: resourceSize)
        }
        return isResourceSizeUnavailable ? "大小不可用" : "正在计算…"
    }

    private var aspectRatio: CGFloat {
        switch displayMode {
        case .square:
            return 1
        case .originalRatio:
            guard item.asset.pixelHeight > 0 else {
                return 1
            }

            return CGFloat(item.asset.pixelWidth) / CGFloat(item.asset.pixelHeight)
        }
    }

    private var selectionOverlay: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0))
                .overlay {
                    Rectangle()
                        .strokeBorder(Color.accentColor.opacity(isSelected ? 1 : 0), lineWidth: 3)
                }

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9), isSelected ? Color.accentColor : Color.black.opacity(0.35))
                .padding(6)
        }
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

    private func requestImage() {
        let identifier = item.localIdentifier
        requestedIdentifier = identifier

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let targetSize: CGSize

        switch displayMode {
        case .square:
            let sideLength = thumbnailWidth * 1.5 * scale
            targetSize = CGSize(width: sideLength, height: sideLength)
        case .originalRatio:
            let longestSide = thumbnailWidth * 1.5 * scale
            let ratio = aspectRatio
            targetSize = ratio >= 1
                ? CGSize(width: longestSide, height: longestSide / ratio)
                : CGSize(width: longestSide * ratio, height: longestSide)
        }

        requestID = imageService.requestThumbnail(
            for: item.asset,
            targetSize: targetSize,
            contentMode: displayMode == .square ? .aspectFill : .aspectFit
        ) { returnedIdentifier, returnedImage in
            guard requestedIdentifier == returnedIdentifier else {
                return
            }

            image = returnedImage
        }
    }

    private func cancelRequest() {
        imageService.cancelRequest(requestID)
        requestID = nil
        requestedIdentifier = nil
    }

    private func requestResourceSizeIfNeeded() {
        guard showsPhotoInfo, isVisible, resourceSizeRequestID == nil,
              resourceSize == nil, !isResourceSizeUnavailable
        else {
            return
        }

        let identifier = item.localIdentifier
        resourceSizeRequestID = imageService.requestResourceSize(for: item.asset) {
            returnedIdentifier, returnedSize in
            guard item.localIdentifier == identifier,
                  returnedIdentifier == identifier else {
                return
            }

            resourceSizeRequestID = nil
            resourceSize = returnedSize
            isResourceSizeUnavailable = returnedSize == nil
        }
    }

    private func cancelResourceSizeRequest() {
        imageService.cancelResourceSizeRequest(resourceSizeRequestID)
        resourceSizeRequestID = nil
    }
}
