import CoreGraphics
import Foundation
import Photos

@MainActor
final class PhotoGridPreheatCoordinator {
    private var assets: [PhotoAssetItem] = []
    private var displayMode: PhotoGridDisplayMode = .originalRatio
    private var thumbnailWidth: CGFloat = 128

    private var visibleAssetIdentifiers = Set<String>()
    private var assetIndexByIdentifier: [String: Int] = [:]
    private var currentPreheatBuckets: [ThumbnailPreheatBucketKey: Set<String>] = [:]
    private var pendingTask: Task<Void, Never>?
    private var generation = 0
    private var lastVisibleWindow: ClosedRange<Int>?
    private var recentScrollDirection: PreheatScrollDirection = .forward

    private weak var imageService: PhotoImageService?
    private let preheatUpdateDelay: Duration = .milliseconds(150)
    private let preheatMaximumAssetCount = 160

    func configure(
        imageService: PhotoImageService,
        assets: [PhotoAssetItem],
        displayMode: PhotoGridDisplayMode,
        thumbnailWidth: CGFloat
    ) {
        self.imageService = imageService
        self.displayMode = displayMode
        self.thumbnailWidth = thumbnailWidth
        replaceAssets(assets)
    }

    func replaceAssets(_ assets: [PhotoAssetItem]) {
        guard assets != self.assets else {
            return
        }

        resetPreheating(resetDiagnostics: true)
        self.assets = assets
        assetIndexByIdentifier = Dictionary(
            uniqueKeysWithValues: assets.enumerated().map { index, item in
                (item.localIdentifier, index)
            }
        )

        #if DEBUG
        ScrollPerformanceDiagnostics.recordPreheatIndexRebuild()
        #endif
    }

    func updateRenderingConfiguration(
        displayMode: PhotoGridDisplayMode,
        thumbnailWidth: CGFloat
    ) {
        self.displayMode = displayMode
        self.thumbnailWidth = thumbnailWidth
        resetPreheating(resetDiagnostics: true)
    }

    func assetAppeared(_ identifier: String) {
        #if DEBUG
        ScrollPerformanceDiagnostics.recordPreheatVisibleEvent()
        #endif

        visibleAssetIdentifiers.insert(identifier)
        schedulePreheatUpdate()
    }

    func assetDisappeared(_ identifier: String) {
        #if DEBUG
        ScrollPerformanceDiagnostics.recordPreheatVisibleEvent()
        #endif

        visibleAssetIdentifiers.remove(identifier)
        schedulePreheatUpdate()
    }

    func resetPreheating(resetDiagnostics: Bool) {
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        visibleAssetIdentifiers.removeAll()
        lastVisibleWindow = nil
        recentScrollDirection = .forward

        #if DEBUG
        if currentPreheatBuckets.isEmpty {
            ScrollPerformanceDiagnostics.updatePreheatedCandidateIdentifiers([])
            ScrollPerformanceDiagnostics.recordPreheatWindowReset()
        }
        #endif

        stopCurrentPreheating(resetDiagnostics: resetDiagnostics)
    }

    private func schedulePreheatUpdate() {
        guard !assets.isEmpty else {
            resetPreheating(resetDiagnostics: false)
            return
        }

        generation += 1
        let scheduledGeneration = generation

        guard pendingTask == nil else {
            return
        }

        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: preheatUpdateDelay)
            guard !Task.isCancelled else {
                return
            }

            processPreheatUpdate(generation: scheduledGeneration)
        }
    }

    private func processPreheatUpdate(generation scheduledGeneration: Int) {
        pendingTask = nil

        guard scheduledGeneration == generation else {
            schedulePreheatUpdate()
            return
        }

        updatePreheatWindow()
    }

    private func updatePreheatWindow() {
        #if DEBUG
        ScrollPerformanceDiagnostics.recordPreheatComputation()
        #endif

        let visibleIndexes = visibleAssetIdentifiers.compactMap {
            assetIndexByIdentifier[$0]
        }

        guard let visibleStart = visibleIndexes.min(),
              let visibleEnd = visibleIndexes.max()
        else {
            stopCurrentPreheating(resetDiagnostics: false)
            return
        }

        let visibleWindow = visibleStart...visibleEnd
        if visibleWindow == lastVisibleWindow {
            #if DEBUG
            ScrollPerformanceDiagnostics.recordPreheatWindowUnchangedSkip()
            #endif
            return
        }

        updateRecentScrollDirection(visibleWindow)
        lastVisibleWindow = visibleWindow

        let estimatedScreenAssetCount = visibleEnd - visibleStart + 1
        let backwardCount = min(estimatedScreenAssetCount, 60)
        let forwardCount = min(estimatedScreenAssetCount * 2, 100)
        let windowStart: Int
        let windowEnd: Int

        switch recentScrollDirection {
        case .forward:
            windowStart = max(0, visibleStart - backwardCount)
            windowEnd = min(assets.count - 1, visibleEnd + forwardCount)
        case .backward:
            windowStart = max(0, visibleStart - forwardCount)
            windowEnd = min(assets.count - 1, visibleEnd + backwardCount)
        }

        let windowItems = Array(assets[windowStart...windowEnd])
        let limitedItems = limitedPreheatItems(
            windowItems,
            visibleIdentifiers: visibleAssetIdentifiers,
            visibleWindow: visibleWindow
        )
        let newBuckets = thumbnailPreheatBuckets(for: limitedItems)

        applyPreheatBuckets(newBuckets)
    }

    private func updateRecentScrollDirection(_ visibleWindow: ClosedRange<Int>) {
        guard let lastVisibleWindow else {
            return
        }

        let previousMidpoint = (lastVisibleWindow.lowerBound + lastVisibleWindow.upperBound) / 2
        let newMidpoint = (visibleWindow.lowerBound + visibleWindow.upperBound) / 2

        if newMidpoint > previousMidpoint {
            recentScrollDirection = .forward
        } else if newMidpoint < previousMidpoint {
            recentScrollDirection = .backward
        }
    }

    private func limitedPreheatItems(
        _ windowItems: [PhotoAssetItem],
        visibleIdentifiers: Set<String>,
        visibleWindow: ClosedRange<Int>
    ) -> [PhotoAssetItem] {
        guard windowItems.count > preheatMaximumAssetCount else {
            return windowItems
        }

        return windowItems.sorted { lhs, rhs in
            preheatPriority(
                for: lhs,
                visibleIdentifiers: visibleIdentifiers,
                visibleWindow: visibleWindow
            ) < preheatPriority(
                for: rhs,
                visibleIdentifiers: visibleIdentifiers,
                visibleWindow: visibleWindow
            )
        }
        .prefix(preheatMaximumAssetCount)
        .map { $0 }
    }

    private func preheatPriority(
        for item: PhotoAssetItem,
        visibleIdentifiers: Set<String>,
        visibleWindow: ClosedRange<Int>
    ) -> Int {
        guard let index = assetIndexByIdentifier[item.localIdentifier] else {
            return Int.max
        }

        if visibleIdentifiers.contains(item.localIdentifier) {
            return index - visibleWindow.lowerBound
        }

        switch recentScrollDirection {
        case .forward:
            if index > visibleWindow.upperBound {
                return 1_000 + index - visibleWindow.upperBound
            }
            return 10_000 + visibleWindow.lowerBound - index
        case .backward:
            if index < visibleWindow.lowerBound {
                return 1_000 + visibleWindow.lowerBound - index
            }
            return 10_000 + index - visibleWindow.upperBound
        }
    }

    private func thumbnailPreheatBuckets(
        for items: [PhotoAssetItem]
    ) -> [ThumbnailPreheatBucketKey: Set<String>] {
        var buckets: [ThumbnailPreheatBucketKey: Set<String>] = [:]

        for item in items {
            guard let imageService else {
                continue
            }

            let configuration = imageService.thumbnailRequestConfiguration(
                for: item.asset,
                displayMode: displayMode,
                thumbnailWidth: thumbnailWidth
            )
            let key = ThumbnailPreheatBucketKey(configuration: configuration)
            buckets[key, default: []].insert(item.localIdentifier)
        }

        return buckets
    }

    private func applyPreheatBuckets(
        _ newBuckets: [ThumbnailPreheatBucketKey: Set<String>]
    ) {
        var addedCount = 0
        var removedCount = 0
        var startCalls = 0
        var stopCalls = 0

        guard let imageService else {
            currentPreheatBuckets = newBuckets
            return
        }

        for key in Set(currentPreheatBuckets.keys).union(newBuckets.keys) {
            let oldIdentifiers = currentPreheatBuckets[key] ?? []
            let newIdentifiers = newBuckets[key] ?? []
            let addedIdentifiers = newIdentifiers.subtracting(oldIdentifiers)
            let removedIdentifiers = oldIdentifiers.subtracting(newIdentifiers)

            let addedAssets = assets(for: addedIdentifiers)
            if !addedAssets.isEmpty {
                imageService.startCachingThumbnails(
                    assets: addedAssets,
                    targetSize: key.targetSize,
                    contentMode: key.contentMode
                )
                addedCount += addedAssets.count
                startCalls += 1
            }

            let removedAssets = assets(for: removedIdentifiers)
            if !removedAssets.isEmpty {
                imageService.stopCachingThumbnails(
                    assets: removedAssets,
                    targetSize: key.targetSize,
                    contentMode: key.contentMode
                )
                removedCount += removedAssets.count
                stopCalls += 1
            }
        }

        currentPreheatBuckets = newBuckets

        #if DEBUG
        ScrollPerformanceDiagnostics.recordPreheatUpdate(
            addedAssets: addedCount,
            removedAssets: removedCount,
            activeAssets: activePreheatedAssetCount,
            startCalls: startCalls,
            stopCalls: stopCalls
        )
        ScrollPerformanceDiagnostics.updatePreheatedCandidateIdentifiers(
            Set(newBuckets.values.flatMap { $0 })
        )
        #endif
    }

    private var activePreheatedAssetCount: Int {
        Set(currentPreheatBuckets.values.flatMap { $0 }).count
    }

    private func stopCurrentPreheating(resetDiagnostics: Bool) {
        guard !currentPreheatBuckets.isEmpty else {
            return
        }

        if resetDiagnostics {
            let removedCount = activePreheatedAssetCount
            imageService?.stopCachingAllThumbnails()
            currentPreheatBuckets = [:]

            #if DEBUG
            ScrollPerformanceDiagnostics.recordPreheatUpdate(
                addedAssets: 0,
                removedAssets: removedCount,
                activeAssets: 0,
                startCalls: 0,
                stopCalls: 1
            )
            ScrollPerformanceDiagnostics.updatePreheatedCandidateIdentifiers([])
            ScrollPerformanceDiagnostics.recordPreheatWindowReset()
            #endif
            return
        }

        var removedCount = 0
        var stopCalls = 0

        guard let imageService else {
            currentPreheatBuckets = [:]
            return
        }

        for (key, identifiers) in currentPreheatBuckets {
            let removedAssets = assets(for: identifiers)
            guard !removedAssets.isEmpty else {
                continue
            }

            imageService.stopCachingThumbnails(
                assets: removedAssets,
                targetSize: key.targetSize,
                contentMode: key.contentMode
            )
            removedCount += removedAssets.count
            stopCalls += 1
        }

        currentPreheatBuckets = [:]

        #if DEBUG
        ScrollPerformanceDiagnostics.recordPreheatUpdate(
            addedAssets: 0,
            removedAssets: removedCount,
            activeAssets: 0,
            startCalls: 0,
            stopCalls: stopCalls
        )
        ScrollPerformanceDiagnostics.updatePreheatedCandidateIdentifiers([])
        #endif
    }

    private func assets(for identifiers: Set<String>) -> [PHAsset] {
        identifiers.compactMap { identifier in
            guard let index = assetIndexByIdentifier[identifier],
                  assets.indices.contains(index)
            else {
                return nil
            }

            return assets[index].asset
        }
    }
}

private enum PreheatScrollDirection {
    case forward
    case backward
}

private struct ThumbnailPreheatBucketKey: Hashable {
    let width: Int
    let height: Int
    let contentModeRawValue: Int

    var targetSize: CGSize {
        CGSize(width: width, height: height)
    }

    var contentMode: PHImageContentMode {
        PHImageContentMode(rawValue: contentModeRawValue) ?? .aspectFill
    }

    init(configuration: PhotoThumbnailRequestConfiguration) {
        width = Int(configuration.targetSize.width.rounded())
        height = Int(configuration.targetSize.height.rounded())
        contentModeRawValue = configuration.contentMode.rawValue
    }
}
