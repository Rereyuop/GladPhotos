import AppKit
import Photos
import SwiftUI

struct PhotoDetailView: View {
    let assets: [PhotoAssetItem]
    let imageService: PhotoImageService
    let deleteAssets: ([PhotoAssetItem]) async throws -> Void
    let compressAsset: (PHAsset) async throws -> CreatedCompressedPhoto
    let onCurrentItemChanged: (PhotoAssetItem) -> Void
    let onClose: () -> Void

    @State private var currentItem: PhotoAssetItem
    @State private var image: NSImage?
    @State private var previewRequestIDs: [String: PHImageRequestID] = [:]
    @State private var previewRequestTokens: [String: UUID] = [:]
    @State private var previewImages: [String: NSImage] = [:]
    @State private var cachedPreviewAssets: [PHAsset] = []
    @StateObject private var livePhotoLoader = LivePhotoLoader()
    @State private var requestedLivePhotoSize: CGSize?
    @State private var isDeleting = false
    @State private var deletionError: String?
    @State private var escapeKeyMonitor: Any?
    @State private var showsSourceInfo = false
    @State private var resourceSize: Int64?
    @State private var resourceSizeRequestID: UUID?
    @State private var swipeOffset: CGFloat = 0
    @State private var isSettlingSwipe = false
    @State private var pageWidth: CGFloat = 1
    @State private var photoInteractionState: PhotoInteractionState = .idle
    @State private var dismissProgress: CGFloat = 0
    @State private var pendingForcedClose = false
    @State private var compressionViewModel: PhotoCompressionViewModel
    private let compressionService = PhotoCompressionService()

    init(
        item: PhotoAssetItem,
        assets: [PhotoAssetItem],
        imageService: PhotoImageService,
        deleteAssets: @escaping ([PhotoAssetItem]) async throws -> Void,
        compressAsset: @escaping (PHAsset) async throws -> CreatedCompressedPhoto,
        onCurrentItemChanged: @escaping (PhotoAssetItem) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.assets = assets
        self.imageService = imageService
        self.deleteAssets = deleteAssets
        self.compressAsset = compressAsset
        self.onCurrentItemChanged = onCurrentItemChanged
        self.onClose = onClose
        _currentItem = State(initialValue: item)
        _compressionViewModel = State(
            initialValue: PhotoCompressionViewModel(assetIdentifier: item.localIdentifier)
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - dismissProgress)
                .ignoresSafeArea()

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
                .task(id: currentItem.localIdentifier) {
                    if currentItem.asset.mediaSubtypes.contains(.photoLive) {
                        loadLivePhoto(for: geometry.size)
                    }
                }
                .onAppear { pageWidth = max(geometry.size.width, 1) }
                .onChange(of: geometry.size) { _, newSize in
                    pageWidth = max(newSize.width, 1)
                    if currentItem.asset.mediaSubtypes.contains(.photoLive) {
                        loadLivePhotoIfSizeChanged(newSize)
                    }
                }
            }
        }
        .navigationTitle(
            currentItem.asset.creationDate?.formatted(
                .dateTime.locale(.gladPhotosChinese)
            ) ?? "照片"
        )
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
                    showAdjacentPhoto(offset: -1)
                } label: {
                    Label("上一张", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!canMove(offset: -1))
                .pointingHandCursor()

                Button {
                    showAdjacentPhoto(offset: 1)
                } label: {
                    Label("下一张", systemImage: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!canMove(offset: 1))
                .pointingHandCursor()

                Button(role: .destructive) {
                    Task {
                        await deleteCurrentPhoto()
                    }
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(isDeleting)
                .pointingHandCursor()

                Button {
                    compressionViewModel.compress(
                        asset: currentItem.asset,
                        operation: compressAsset,
                        onCreated: { currentItem = $0 }
                    )
                } label: {
                    Label(
                        compressionViewModel.isCompressing ? "压缩中…" : "压缩",
                        systemImage: "arrow.down.right.and.arrow.up.left"
                    )
                }
                .disabled(
                    compressionViewModel.isCompressing ||
                    !compressionService.isSupported(currentItem.asset)
                )
                .help(compressionService.isSupported(currentItem.asset) ? "压缩为 JPEG" : "仅支持普通 JPEG、HEIC 和 PNG")
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
        .overlay(alignment: .top) {
            if let message = compressionViewModel.successMessage {
                Text(message)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
            }
        }
        .task(id: currentItem.localIdentifier) {
            onCurrentItemChanged(currentItem)
            compressionViewModel.display(assetIdentifier: currentItem.localIdentifier)
            loadResourceSize()
            loadPreviewWindow()
            if currentItem.asset.mediaSubtypes.contains(.photoLive) {
                image = nil
            } else {
                livePhotoLoader.cancel()
                requestedLivePhotoSize = nil
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
            previewRequestIDs.values.forEach(imageService.cancelRequest)
            previewRequestIDs.removeAll()
            previewRequestTokens.removeAll()
            imageService.stopCachingPreviews(
                for: cachedPreviewAssets,
                targetSize: previewTargetSize
            )
            cachedPreviewAssets.removeAll()
            imageService.cancelResourceSizeRequest(resourceSizeRequestID)
            livePhotoLoader.cancel()
        }
        .alert("删除失败", isPresented: deletionErrorBinding) {
            Button("好", role: .cancel) {
                deletionError = nil
            }
            .pointingHandCursor()
        } message: {
            Text(deletionError ?? "")
        }
        .alert("压缩失败", isPresented: compressionErrorBinding) {
            Button("好", role: .cancel) { compressionViewModel.errorMessage = nil }
                .pointingHandCursor()
        } message: {
            Text(compressionViewModel.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func pageContent(relativeOffset: Int) -> some View {
        if relativeOffset == 0 {
            if currentItem.asset.mediaSubtypes.contains(.photoLive) {
                livePhotoContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image {
                ZoomablePhotoView(
                    image: image,
                    pixelSize: CGSize(
                        width: currentItem.asset.pixelWidth,
                        height: currentItem.asset.pixelHeight
                    ),
                    onHorizontalSwipe: handleHorizontalSwipe,
                    onDismiss: onClose,
                    onInteractionStateChanged: { photoInteractionState = $0 },
                    onDismissProgressChanged: { dismissProgress = $0 }
                )
                .id(currentItem.localIdentifier)
            } else {
                loadingView
            }
        } else if let item = item(relativeOffset: relativeOffset),
                  let preview = previewImages[item.localIdentifier] {
            Image(nsImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(.horizontal, 1)
        } else {
            Color.black
        }
    }

    private var loadingView: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var livePhotoContent: some View {
        if let livePhoto = livePhotoLoader.livePhoto {
            ZoomableLivePhotoView(
                livePhoto: livePhoto,
                assetIdentifier: currentItem.localIdentifier,
                pixelSize: CGSize(
                    width: currentItem.asset.pixelWidth,
                    height: currentItem.asset.pixelHeight
                ),
                onHorizontalSwipe: handleHorizontalSwipe,
                onDismiss: onClose,
                onInteractionStateChanged: { photoInteractionState = $0 },
                onDismissProgressChanged: { dismissProgress = $0 }
            )
        } else if let errorMessage = livePhotoLoader.errorMessage {
            VStack(spacing: 12) {
                Text(errorMessage)
                    .foregroundStyle(.white)

                Button("重试") {
                    if let requestedLivePhotoSize {
                        livePhotoLoader.load(
                            asset: currentItem.asset,
                            targetSize: requestedLivePhotoSize
                        )
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
        assets.firstIndex(of: currentItem)
    }

    private var deletionErrorBinding: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { isPresented in
                if !isPresented {
                    deletionError = nil
                }
            }
        )
    }

    private var compressionErrorBinding: Binding<Bool> {
        Binding(
            get: { compressionViewModel.errorMessage != nil },
            set: { if !$0 { compressionViewModel.errorMessage = nil } }
        )
    }

    private var imageMetadata: ImageSourceMetadata {
        let resource = PHAssetResource.assetResources(for: currentItem.asset).first
        let filename = resource?.originalFilename
        return ImageSourceMetadata(
            filename: filename,
            codec: filename.map { URL(fileURLWithPath: $0).pathExtension.uppercased() },
            width: currentItem.asset.pixelWidth,
            height: currentItem.asset.pixelHeight,
            fileSize: resourceSize,
            creationDate: currentItem.asset.creationDate
        )
    }

    private func loadResourceSize() {
        imageService.cancelResourceSizeRequest(resourceSizeRequestID)
        resourceSizeRequestID = nil
        resourceSize = nil
        let identifier = currentItem.localIdentifier
        resourceSizeRequestID = imageService.requestResourceSize(for: currentItem.asset) {
            loadedIdentifier, size in
            guard loadedIdentifier == identifier,
                  loadedIdentifier == currentItem.localIdentifier else {
                return
            }
            resourceSize = size
            resourceSizeRequestID = nil
        }
    }

    private func canMove(offset: Int) -> Bool {
        guard let currentIndex else {
            return false
        }

        return assets.indices.contains(currentIndex + offset)
    }

    private func item(relativeOffset: Int) -> PhotoAssetItem? {
        guard let currentIndex else { return nil }
        let index = currentIndex + relativeOffset
        return assets.indices.contains(index) ? assets[index] : nil
    }

    private func showAdjacentPhoto(offset: Int) {
        guard let currentIndex else {
            return
        }

        let newIndex = currentIndex + offset
        guard assets.indices.contains(newIndex) else {
            return
        }

        let newItem = assets[newIndex]
        compressionViewModel.display(assetIdentifier: newItem.localIdentifier)
        currentItem = newItem
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
                showAdjacentPhoto(offset: direction)
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

    private func startMonitoringEscapeKey() {
        guard escapeKeyMonitor == nil else {
            return
        }

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            guard event.keyCode == 53, deletionError == nil else {
                return event
            }

            requestClose()
            return nil
        }
    }

    private func stopMonitoringEscapeKey() {
        guard let escapeKeyMonitor else {
            return
        }

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

    private func loadPreviewWindow() {
        let windowItems = [-1, 0, 1].compactMap { item(relativeOffset: $0) }
        let retainedIDs = Set(windowItems.map(\.localIdentifier))

        let staleRequests = previewRequestIDs.filter {
            !retainedIDs.contains($0.key)
        }
        for (identifier, requestID) in staleRequests {
            imageService.cancelRequest(requestID)
            previewRequestIDs[identifier] = nil
            previewRequestTokens[identifier] = nil
        }

        previewImages = previewImages.filter { retainedIDs.contains($0.key) }
        image = previewImages[currentItem.localIdentifier]

        imageService.stopCachingPreviews(
            for: cachedPreviewAssets,
            targetSize: previewTargetSize
        )
        cachedPreviewAssets = windowItems.map(\.asset)
        imageService.startCachingPreviews(
            for: cachedPreviewAssets,
            targetSize: previewTargetSize
        )
        for item in windowItems
        where previewImages[item.localIdentifier] == nil &&
              previewRequestIDs[item.localIdentifier] == nil {
            let identifier = item.localIdentifier
            let token = UUID()
            previewRequestTokens[identifier] = token
            previewRequestIDs[identifier] = imageService.requestPreview(
                for: item.asset,
                targetSize: previewTargetSize
            ) { loadedIdentifier, loadedImage in
                guard previewRequestTokens[loadedIdentifier] == token else {
                    return
                }

                previewRequestIDs[loadedIdentifier] = nil
                previewRequestTokens[loadedIdentifier] = nil
                guard let loadedImage else { return }
                previewImages[loadedIdentifier] = loadedImage
                if loadedIdentifier == currentItem.localIdentifier,
                   !currentItem.asset.mediaSubtypes.contains(.photoLive) {
                    image = loadedImage
                }
            }
        }
    }

    private var previewTargetSize: CGSize {
        CGSize(width: 2400, height: 1600)
    }

    private func loadLivePhoto(for displaySize: CGSize) {
        guard displaySize.width > 0, displaySize.height > 0 else {
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let targetSize = CGSize(
            width: displaySize.width * scale,
            height: displaySize.height * scale
        )
        requestedLivePhotoSize = targetSize
        livePhotoLoader.load(asset: currentItem.asset, targetSize: targetSize)
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

        let changedSignificantly =
            abs(newSize.width - requestedLivePhotoSize.width) >= 100 ||
            abs(newSize.height - requestedLivePhotoSize.height) >= 100
        if changedSignificantly {
            loadLivePhoto(for: displaySize)
        }
    }

    private func deleteCurrentPhoto() async {
        guard let currentIndex else {
            return
        }

        let itemToDelete = currentItem
        let replacementItem: PhotoAssetItem? = if assets.indices.contains(currentIndex + 1) {
            assets[currentIndex + 1]
        } else if assets.indices.contains(currentIndex - 1) {
            assets[currentIndex - 1]
        } else {
            nil
        }

        isDeleting = true
        defer { isDeleting = false }

        do {
            try await deleteAssets([itemToDelete])

            if let replacementItem {
                compressionViewModel.display(assetIdentifier: replacementItem.localIdentifier)
                currentItem = replacementItem
            } else {
                onClose()
            }
        } catch {
            if !error.isPhotoLibraryUserCancellation {
                deletionError = error.localizedDescription
            }
        }
    }
}
