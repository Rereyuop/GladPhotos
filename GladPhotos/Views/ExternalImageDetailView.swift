import AppKit
import ImageIO
import Photos
import SwiftUI

struct ExternalImageDetailView: View {
    let items: [ExternalMediaItem]
    let thumbnailService: ExternalThumbnailService
    let deleteItem: (ExternalMediaItem) async throws -> Void
    let onClose: () -> Void

    @State private var currentItem: ExternalMediaItem
    @State private var placeholderImage: NSImage?
    @State private var detailImage: NSImage?
    @State private var detailImageItemID: ExternalMediaItem.ID?
    @State private var detailLoadState: ExternalDetailLoadState = .idle
    @State private var requestedPixelSize: CGSize = .zero
    @State private var returnedPixelSize: CGSize = .zero
    @State private var previewImages: [ExternalMediaItem.ID: NSImage] = [:]
    @StateObject private var livePhotoLoader = ExternalLivePhotoLoader()
    @State private var requestedLivePhotoSize: CGSize?
    @State private var escapeKeyMonitor: Any?
    @State private var showsDeleteConfirmation = false
    @State private var deletionError: String?
    @State private var isDeleting = false
    @State private var showsSourceInfo = false
    @State private var swipeOffset: CGFloat = 0
    @State private var isSettlingSwipe = false
    @State private var pageWidth: CGFloat = 1
    @State private var photoInteractionState: PhotoInteractionState = .idle
    @State private var dismissProgress: CGFloat = 0
    @State private var pendingForcedClose = false
    @Environment(\.displayScale) private var displayScale

    init(
        item: ExternalMediaItem,
        items: [ExternalMediaItem],
        thumbnailService: ExternalThumbnailService,
        deleteItem: @escaping (ExternalMediaItem) async throws -> Void,
        onClose: @escaping () -> Void = {}
    ) {
        self.items = items
        self.thumbnailService = thumbnailService
        self.deleteItem = deleteItem
        self.onClose = onClose
        _currentItem = State(initialValue: item)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - dismissProgress).ignoresSafeArea()

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach([-1, 0, 1], id: \.self) { relativeOffset in
                        pageContent(relativeOffset: relativeOffset)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .frame(width: geometry.size.width * 3, alignment: .leading)
                .offset(x: -geometry.size.width + swipeOffset)
                .clipped()
                .task(id: currentItem.id) {
                    if currentItem.isLivePhoto {
                        loadLivePhoto(for: geometry.size)
                    }
                }
                .onAppear { pageWidth = max(geometry.size.width, 1) }
                .onChange(of: geometry.size) { _, newSize in
                    pageWidth = max(newSize.width, 1)
                    if currentItem.isLivePhoto {
                        loadLivePhotoIfSizeChanged(newSize)
                    }
                }
                .task(id: detailRequestID(size: geometry.size)) {
                    guard !currentItem.isLivePhoto else { return }
                    await loadDetailImage(for: currentItem, viewSize: geometry.size)
                }
            }
        }
        .navigationTitle(detailTitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsSourceInfo.toggle()
                    }
                } label: {
                    Label(
                        "图片信息",
                        systemImage: showsSourceInfo ? "info.circle.fill" : "info.circle"
                    )
                }
                .keyboardShortcut("i", modifiers: [])
                .help(showsSourceInfo ? "关闭图片信息" : "显示图片信息")
                .pointingHandCursor()

                Button {
                    showAdjacentImage(offset: -1)
                } label: {
                    Label("上一张", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!canMove(offset: -1))
                .pointingHandCursor()

                Button {
                    showAdjacentImage(offset: 1)
                } label: {
                    Label("下一张", systemImage: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!canMove(offset: 1))
                .pointingHandCursor()

                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .help(currentItem.isLivePhoto ? "将 HEIC 和 MOV 源文件移到废纸篓" : "将源文件移到废纸篓")
                .disabled(isDeleting)
                .pointingHandCursor()
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsSourceInfo {
                ImageSourceInfoPanel(metadata: imageMetadata)
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .task(id: currentItem.id) {
            resetDetailState()
            await loadPreviewWindow()
            if currentItem.isLivePhoto {
                placeholderImage = nil
                detailImage = nil
                requestedLivePhotoSize = nil
            } else {
                livePhotoLoader.cancel()
                placeholderImage = previewImages[currentItem.id]
            }
        }
        .onExitCommand {
            requestClose()
        }
        .onChange(of: photoInteractionState) { _, state in
            if pendingForcedClose, state == .idle {
                pendingForcedClose = false
                onClose()
            }
        }
        .onAppear {
            startMonitoringEscapeKey()
        }
        .onDisappear {
            stopMonitoringEscapeKey()
            livePhotoLoader.cancel()
            resetDetailState(reason: "detail view disappeared")
        }
        .alert(deleteConfirmationTitle, isPresented: $showsDeleteConfirmation) {
            Button("取消", role: .cancel) {}
                .pointingHandCursor()
            Button("移到废纸篓", role: .destructive) {
                Task { await deleteCurrentItem() }
            }
            .pointingHandCursor()
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert("删除失败", isPresented: deletionErrorBinding) {
            Button("好", role: .cancel) { deletionError = nil }
                .pointingHandCursor()
        } message: {
            Text(deletionError ?? "")
        }
    }

    @ViewBuilder
    private func pageContent(relativeOffset: Int) -> some View {
        if relativeOffset == 0 {
            if currentItem.isLivePhoto {
                livePhotoContent
            } else if let image = displayedImage {
                ZoomablePhotoView(
                    image: image,
                    pixelSize: imagePixelSize(image),
                    onHorizontalSwipe: handleHorizontalSwipe,
                    onDismiss: onClose,
                    onInteractionStateChanged: { photoInteractionState = $0 },
                    onDismissProgressChanged: { dismissProgress = $0 }
                )
                .id(currentItem.id)
            } else if detailLoadState == .failed {
                ContentUnavailableView(
                    "无法显示图片",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("文件可能已损坏、被移除或无法访问。")
                )
                .foregroundStyle(.white)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        } else if let item = item(relativeOffset: relativeOffset),
                  let preview = previewImages[item.id] {
            Image(nsImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(.horizontal, 1)
        } else {
            Color.black
        }
    }

    @ViewBuilder
    private var livePhotoContent: some View {
        if let livePhoto = livePhotoLoader.livePhoto {
            ZoomableLivePhotoView(
                livePhoto: livePhoto,
                assetIdentifier: currentItem.url.path,
                pixelSize: livePhoto.size,
                onHorizontalSwipe: handleHorizontalSwipe,
                onDismiss: onClose,
                onInteractionStateChanged: { photoInteractionState = $0 },
                onDismissProgressChanged: { dismissProgress = $0 }
            )
        } else if let errorMessage = livePhotoLoader.errorMessage {
            VStack(spacing: 12) {
                Text(errorMessage).foregroundStyle(.white)
                Button("重试") {
                    if let requestedLivePhotoSize {
                        loadLivePhoto(targetSize: requestedLivePhotoSize)
                    }
                }
                .pointingHandCursor()
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    private var currentIndex: Int? {
        items.firstIndex(of: currentItem)
    }

    private var detailTitle: String {
        currentItem.displayDate?.formatted(
            .dateTime.locale(.gladPhotosChinese)
        ) ?? "照片"
    }

    private var deleteConfirmationTitle: String {
        currentItem.isLivePhoto ? "删除这张实况照片？" : "删除这张照片？"
    }

    private var deleteConfirmationMessage: String {
        if let pairedVideoURL = currentItem.pairedVideoURL {
            return "将同时把源文件“\(currentItem.filename)”和“\(pairedVideoURL.lastPathComponent)”移到废纸篓。"
        }
        return "将把源文件“\(currentItem.filename)”移到废纸篓。"
    }

    private var deletionErrorBinding: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )
    }

    private func deleteCurrentItem() async {
        guard !isDeleting else { return }
        isDeleting = true
        let itemToDelete = currentItem

        do {
            try await deleteItem(itemToDelete)
            onClose()
        } catch {
            deletionError = error.localizedDescription
        }
        isDeleting = false
    }

    private var imageMetadata: ImageSourceMetadata {
        let representation = displayedImage?.representations.max {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        }
        return ImageSourceMetadata(
            filename: currentItem.filename,
            codec: currentItem.url.pathExtension.uppercased(),
            width: representation?.pixelsWide,
            height: representation?.pixelsHigh,
            fileSize: currentItem.fileSize,
            creationDate: currentItem.displayDate
        )
    }

    private var displayedImage: NSImage? {
        if let detailImage, detailImageSatisfiesCurrentRequest {
            return detailImage
        }
        return placeholderImage
    }

    private var detailImageSatisfiesCurrentRequest: Bool {
        detailImageItemID == currentItem.id &&
            (returnedPixelSize.width >= requestedPixelSize.width * 0.98 ||
                returnedPixelSize.height >= requestedPixelSize.height * 0.98)
    }

    private func imagePixelSize(_ image: NSImage) -> CGSize {
        guard let representation = image.representations.max(by: {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        }) else {
            return image.size
        }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    private func canMove(offset: Int) -> Bool {
        guard let currentIndex else { return false }
        return items.indices.contains(currentIndex + offset)
    }

    private func item(relativeOffset: Int) -> ExternalMediaItem? {
        guard let currentIndex else { return nil }
        let index = currentIndex + relativeOffset
        return items.indices.contains(index) ? items[index] : nil
    }

    private func showAdjacentImage(offset: Int) {
        guard let currentIndex else { return }
        let newIndex = currentIndex + offset
        guard items.indices.contains(newIndex) else { return }
        currentItem = items[newIndex]
    }

    private func handleHorizontalSwipe(_ event: HorizontalSwipeEvent) {
        guard !isSettlingSwipe, photoInteractionState == .idle else { return }

        switch event {
        case .changed(let translation, _, _):
            let direction = translation < 0 ? 1 : -1
            swipeOffset = canMove(offset: direction) ? translation : edgeDamped(translation)

        case .ended(let translation, let velocity, let predictedEndTranslation):
            let decisionOffset = abs(predictedEndTranslation) > abs(translation)
                ? predictedEndTranslation : translation
            let direction = decisionOffset < 0 ? 1 : -1
            let passedDistance = abs(translation) >= pageWidth * 0.2
            let wasFlicked = abs(velocity) >= 700 && abs(predictedEndTranslation) >= 70
            let shouldMove = (passedDistance || wasFlicked) && canMove(offset: direction)
            guard shouldMove else {
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                    swipeOffset = 0
                }
                return
            }

            isSettlingSwipe = true
            withAnimation(
                .interactiveSpring(response: 0.34, dampingFraction: 0.9),
                completionCriteria: .logicallyComplete
            ) {
                swipeOffset = direction > 0 ? -pageWidth : pageWidth
            } completion: {
                showAdjacentImage(offset: direction)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { swipeOffset = 0 }
                isSettlingSwipe = false
            }
        }
    }

    private func edgeDamped(_ translation: CGFloat) -> CGFloat {
        let magnitude = abs(translation)
        let damped = magnitude / (1 + magnitude / max(pageWidth * 0.35, 1))
        return translation.sign == .minus ? -damped : damped
    }

    private func loadPreviewWindow() async {
        let windowItems = [-1, 0, 1].compactMap { item(relativeOffset: $0) }
        let retainedIDs = Set(windowItems.map(\.id))
        previewImages = previewImages.filter { retainedIDs.contains($0.key) }

        for item in windowItems where previewImages[item.id] == nil {
            let loadedImage: NSImage?
            if let cached = cachedPlaceholder(for: item) {
                loadedImage = cached
            } else {
                loadedImage = await thumbnailService.image(
                    for: item,
                    maxPixelSize: CGFloat(ThumbnailTier.maximum.pixels),
                    allowEmbeddedThumbnail: false
                )
            }
            if let loadedImage {
                previewImages[item.id] = loadedImage
                if item.id == currentItem.id, !currentItem.isLivePhoto {
                    placeholderImage = loadedImage
                    logDetail(
                        "placeholder loaded source=ExternalThumbnailService size=\(ExternalImageDetailPipeline.pixelSize(of: loadedImage))"
                    )
                }
            }
        }
        if !currentItem.isLivePhoto {
            placeholderImage = previewImages[currentItem.id]
        }
    }

    private func cachedPlaceholder(for item: ExternalMediaItem) -> NSImage? {
        guard let cached = thumbnailService.cachedThumbnail(
            for: item,
            maxPixelSize: CGFloat(ThumbnailTier.maximum.pixels),
            sizing: .longestEdge
        ) else { return nil }
        logDetail(
            "placeholder loaded source=RecentThumbnailLRU/NSCache size=\(ExternalImageDetailPipeline.pixelSize(of: cached.image)) tier=\(cached.tier.pixels)"
        )
        return cached.image
    }

    private func loadDetailImage(for item: ExternalMediaItem, viewSize: CGSize) async {
        guard viewSize.width > 1, viewSize.height > 1 else { return }
        let scale = effectiveDisplayScale
        let request = ExternalImageDetailPipeline.request(
            for: item,
            viewSize: viewSize,
            backingScale: scale
        )
        requestedPixelSize = request.requestedPixelSize
        guard !detailImageSatisfiesCurrentRequest else {
            detailLoadState = .loaded
            logDetail("detail skipped existing image satisfies request returned=\(returnedPixelSize) requested=\(requestedPixelSize)")
            return
        }

        detailLoadState = .loading
        let placeholderSize = placeholderImage.map(ExternalImageDetailPipeline.pixelSize(of:)) ?? .zero
        logDetail(
            "detail task scheduled sourcePath=\(item.url.path) placeholderSize=\(placeholderSize) viewPoints=\(viewSize) backingScale=\(scale) requestedDetailPixels=\(request.requestedPixelSize) requestedLongestEdge=\(request.maxPixelSize) sourceOriginal=\(request.originalPixelSize)"
        )

        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            detailLoadState = .cancelled
            logDetail("detail task cancelled during debounce requestedDetailPixels=\(request.requestedPixelSize)")
            return
        }
        guard !Task.isCancelled else {
            detailLoadState = .cancelled
            logDetail("detail task cancelled before decode requestedDetailPixels=\(request.requestedPixelSize)")
            return
        }

        let result = await ExternalImageDetailDecodeLimiter.shared.decode(
            item: item,
            maxPixelSize: request.maxPixelSize,
            requestedPixelSize: request.requestedPixelSize
        )

        guard !Task.isCancelled else {
            detailLoadState = .cancelled
            logDetail("detail task cancelled after decode requestedDetailPixels=\(request.requestedPixelSize)")
            return
        }
        guard currentItem.id == item.id else {
            logDetail("detail task completed ignored stale mediaID=\(item.stableMediaID)")
            return
        }

        guard let result else {
            detailLoadState = .failed
            logDetail("detail task completed failed finalDisplayedSource=\(placeholderImage == nil ? "none" : "placeholder")")
            return
        }

        returnedPixelSize = result.pixelSize
        detailImage = result.image
        detailImageItemID = item.id
        let isFullResolution = result.pixelSize.width >= result.originalPixelSize.width &&
            result.pixelSize.height >= result.originalPixelSize.height
        detailLoadState = detailImageSatisfiesCurrentRequest ? .loaded : .loading
        logDetail(
            "detail task completed source=ImageIO detail decode returnedDetailPixels=\(result.pixelSize) requestedDetailPixels=\(request.requestedPixelSize) finalDisplayedSource=\(detailImageSatisfiesCurrentRequest ? "ImageIO detail decode" : "placeholder until upgrade") fullResolutionState=\(isFullResolution ? "full-resolution original" : "downsampled detail")"
        )
    }

    private var effectiveDisplayScale: CGFloat {
        if displayScale > 0 { return displayScale }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    private func detailRequestID(size: CGSize) -> String {
        let scale = effectiveDisplayScale
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        return "\(currentItem.id)#\(width)x\(height)"
    }

    private func resetDetailState(reason: String = "item changed") {
        let releasedDetailBytes = detailImage.map { ExternalImageDetailPipeline.estimatedDecodedBytes(of: $0) } ?? 0
        let releasedPlaceholderBytes = placeholderImage.map { ExternalImageDetailPipeline.estimatedDecodedBytes(of: $0) } ?? 0
        if releasedDetailBytes > 0 || releasedPlaceholderBytes > 0 {
            logDetail(
                "release reason=\(reason) detailBytes=\(releasedDetailBytes) placeholderBytes=\(releasedPlaceholderBytes)"
            )
        }
        placeholderImage = nil
        detailImage = nil
        detailImageItemID = nil
        detailLoadState = .idle
        requestedPixelSize = .zero
        returnedPixelSize = .zero
    }

    private func logDetail(_ message: String) {
        print("[ExternalImageDetail] mediaID=\(currentItem.stableMediaID) path=\(currentItem.url.path) \(message)")
    }

    private func loadLivePhoto(for displaySize: CGSize) {
        guard displaySize.width > 0, displaySize.height > 0 else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        loadLivePhoto(
            targetSize: CGSize(
                width: displaySize.width * scale,
                height: displaySize.height * scale
            )
        )
    }

    private func loadLivePhoto(targetSize: CGSize) {
        guard let videoURL = currentItem.pairedVideoURL else { return }
        requestedLivePhotoSize = targetSize
        livePhotoLoader.load(
            imageURL: currentItem.url,
            videoURL: videoURL,
            targetSize: targetSize
        )
    }

    private func loadLivePhotoIfSizeChanged(_ displaySize: CGSize) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let newSize = CGSize(
            width: displaySize.width * scale,
            height: displaySize.height * scale
        )
        guard let requestedLivePhotoSize else {
            loadLivePhoto(for: displaySize)
            return
        }
        if abs(newSize.width - requestedLivePhotoSize.width) >= 100 ||
            abs(newSize.height - requestedLivePhotoSize.height) >= 100 {
            loadLivePhoto(targetSize: newSize)
        }
    }

    private func startMonitoringEscapeKey() {
        guard escapeKeyMonitor == nil else { return }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, !showsDeleteConfirmation else { return event }
            requestClose()
            return nil
        }
    }

    private func stopMonitoringEscapeKey() {
        guard let escapeKeyMonitor else { return }
        NSEvent.removeMonitor(escapeKeyMonitor)
        self.escapeKeyMonitor = nil
    }

    private func requestClose() {
        if photoInteractionState == .idle {
            onClose()
        } else {
            pendingForcedClose = true
        }
    }
}

private enum ExternalDetailLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
    case cancelled
}

private enum ExternalImageDetailPipeline {
    struct Request {
        let requestedPixelSize: CGSize
        let maxPixelSize: Int
        let originalPixelSize: CGSize
    }

    struct Result {
        let image: NSImage
        let pixelSize: CGSize
        let originalPixelSize: CGSize
    }

    nonisolated static func request(
        for item: ExternalMediaItem,
        viewSize: CGSize,
        backingScale: CGFloat
    ) -> Request {
        let requestedPixelSize = CGSize(
            width: max(1, (viewSize.width * backingScale).rounded(.up)),
            height: max(1, (viewSize.height * backingScale).rounded(.up))
        )
        let originalSize = originalPixelSize(at: item.url)
            ?? CGSize(
                width: item.pixelWidth ?? Int(requestedPixelSize.width),
                height: item.pixelHeight ?? Int(requestedPixelSize.height)
            )
        let requestedLongest = Int(max(requestedPixelSize.width, requestedPixelSize.height).rounded(.up))
        let originalLongest = Int(max(originalSize.width, originalSize.height).rounded(.up))
        let detailFloor = min(originalLongest, 4_096)
        return Request(
            requestedPixelSize: requestedPixelSize,
            maxPixelSize: max(requestedLongest, detailFloor),
            originalPixelSize: originalSize
        )
    }

    nonisolated static func decode(item: ExternalMediaItem, maxPixelSize: Int) -> Result? {
        guard !Task.isCancelled else { return nil }
        guard let source = CGImageSourceCreateWithURL(
            item.url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        guard !Task.isCancelled else { return nil }

        let index = CGImageSourceGetPrimaryImageIndex(source)
        let originalSize = originalPixelSize(source: source, index: index)
            ?? CGSize(width: item.pixelWidth ?? maxPixelSize, height: item.pixelHeight ?? maxPixelSize)
        let boundedPixels = min(max(maxPixelSize, 1), max(Int(max(originalSize.width, originalSize.height)), 1))
        guard !Task.isCancelled else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: boundedPixels
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        return Result(
            image: image,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            originalPixelSize: originalSize
        )
    }

    nonisolated static func pixelSize(of image: NSImage) -> CGSize {
        guard let representation = image.representations.max(by: {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        }) else { return image.size }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    nonisolated static func estimatedDecodedBytes(of image: NSImage) -> Int {
        let size = pixelSize(of: image)
        return max(0, Int(size.width * size.height * 4))
    }

    nonisolated static func estimatedDecodedBytes(for pixelSize: CGSize) -> Int {
        max(0, Int(pixelSize.width * pixelSize.height * 4))
    }

    nonisolated private static func originalPixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return originalPixelSize(source: source, index: CGImageSourceGetPrimaryImageIndex(source))
    }

    nonisolated private static func originalPixelSize(
        source: CGImageSource,
        index: Int
    ) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        if (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }
}

private actor ExternalImageDetailDecodeLimiter {
    static let shared = ExternalImageDetailDecodeLimiter()

    private var activeDecodeCount = 0

    func decode(
        item: ExternalMediaItem,
        maxPixelSize: Int,
        requestedPixelSize: CGSize
    ) async -> ExternalImageDetailPipeline.Result? {
        guard !Task.isCancelled else {
            log(
                "detail decode skipped cancelled-before-start activeDecodes=\(activeDecodeCount) mediaID=\(item.stableMediaID) requestedPixels=\(requestedPixelSize)"
            )
            return nil
        }

        activeDecodeCount += 1
        let activeAtStart = activeDecodeCount
        let start = ContinuousClock.now
        let requestedBytes = ExternalImageDetailPipeline.estimatedDecodedBytes(for: requestedPixelSize)
        log(
            "detail decode started activeDecodes=\(activeAtStart) mediaID=\(item.stableMediaID) requestedPixels=\(requestedPixelSize) requestedBytes=\(requestedBytes)"
        )
        defer {
            activeDecodeCount = max(0, activeDecodeCount - 1)
            log(
                "detail decode released activeDecodes=\(activeDecodeCount) mediaID=\(item.stableMediaID)"
            )
        }

        guard !Task.isCancelled else {
            log(
                "detail decode cancelled-before-imageio activeDecodes=\(activeAtStart) mediaID=\(item.stableMediaID)"
            )
            return nil
        }

        let result = ExternalImageDetailPipeline.decode(item: item, maxPixelSize: maxPixelSize)
        let milliseconds = start.duration(to: .now).externalDetailMilliseconds

        guard !Task.isCancelled else {
            log(
                String(format:
                    "detail decode cancelled-after-imageio activeDecodes=%d mediaID=%@ duration=%.2fms",
                    activeAtStart,
                    item.stableMediaID,
                    milliseconds
                )
            )
            return nil
        }

        if let result {
            let returnedBytes = ExternalImageDetailPipeline.estimatedDecodedBytes(for: result.pixelSize)
            log(
                String(format:
                    "detail decode completed activeDecodes=%d mediaID=%@ requestedPixels=%@ returnedPixels=%@ duration=%.2fms estimatedDecodedBytes=%d",
                    activeAtStart,
                    item.stableMediaID,
                    String(describing: requestedPixelSize),
                    String(describing: result.pixelSize),
                    milliseconds,
                    returnedBytes
                )
            )
        } else {
            log(
                String(format:
                    "detail decode failed activeDecodes=%d mediaID=%@ requestedPixels=%@ duration=%.2fms",
                    activeAtStart,
                    item.stableMediaID,
                    String(describing: requestedPixelSize),
                    milliseconds
                )
            )
        }
        return result
    }

    private func log(_ message: String) {
        print("[ExternalImageDetail] \(message)")
    }
}

nonisolated private extension Duration {
    var externalDetailMilliseconds: Double {
        Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
    }
}
