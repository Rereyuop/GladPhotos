import AppKit
import Photos

@MainActor
final class PhotoImageService {
    private let imageManager = PHCachingImageManager()
    private let resourceManager = PHAssetResourceManager.default()
    private var resourceSizeCache: [String: Int64] = [:]
    private var resourceSizeRequests: [UUID: ResourceSizeRequest] = [:]

    private final class ByteAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var byteCount: Int64 = 0

        func add(_ count: Int) {
            lock.lock()
            byteCount += Int64(count)
            lock.unlock()
        }

        func value() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return byteCount
        }
    }

    private struct ResourceSizeRequest {
        let identifier: String
        let accumulator: ByteAccumulator
        var dataRequestIDs: [PHAssetResourceDataRequestID]
        var remainingResourceCount: Int
        var encounteredError = false
        let completion: (String, Int64?) -> Void
    }

    func requestThumbnail(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        completion: @escaping (String, NSImage?, Bool) -> Void
    ) -> PHImageRequestID {
        let identifier = asset.localIdentifier
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        #if DEBUG
        guard ScrollPerformanceDiagnostics.isEnabled else {
            return imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                Task { @MainActor in
                    completion(identifier, image, isDegraded)
                }
            }
        }

        let diagnosticKey = ScrollPerformanceDiagnostics.makeThumbnailRequestKey(
            assetIdentifier: identifier,
            targetSize: targetSize,
            contentMode: contentMode
        )
        var requestID = PHInvalidImageRequestID
        requestID = imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        ) { image, info in
            let wasCancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let hasError = info?[PHImageErrorKey] != nil

            Task { @MainActor in
                ScrollPerformanceDiagnostics.recordThumbnailCallback(
                    requestID: requestID,
                    isDegraded: isDegraded,
                    isCancelled: wasCancelled,
                    hasError: hasError
                )
                completion(identifier, image, isDegraded)
            }
        }
        ScrollPerformanceDiagnostics.recordThumbnailRequestStarted(
            requestID: requestID,
            key: diagnosticKey,
            targetSize: targetSize
        )
        return requestID
        #else
        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            Task { @MainActor in
                completion(identifier, image, isDegraded)
            }
        }
        #endif
    }

    func requestPreview(
        for asset: PHAsset,
        targetSize: CGSize,
        completion: @escaping (String, NSImage?) -> Void
    ) -> PHImageRequestID {
        let identifier = asset.localIdentifier
        let options = previewRequestOptions()

        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let wasCancelled = (info?[PHImageCancelledKey] as? Bool) == true
            guard !wasCancelled else {
                return
            }

            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            guard !isDegraded else {
                return
            }

            Task { @MainActor in
                completion(identifier, image)
            }
        }
    }

    func startCachingPreviews(
        for assets: [PHAsset],
        targetSize: CGSize
    ) {
        guard !assets.isEmpty else {
            return
        }

        imageManager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: previewRequestOptions()
        )
    }

    func stopCachingPreviews(
        for assets: [PHAsset],
        targetSize: CGSize
    ) {
        guard !assets.isEmpty else {
            return
        }

        imageManager.stopCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: previewRequestOptions()
        )
    }

    func cancelRequest(_ requestID: PHImageRequestID?) {
        guard let requestID else {
            return
        }

        #if DEBUG
        ScrollPerformanceDiagnostics.recordThumbnailRequestCancelled(requestID)
        #endif
        imageManager.cancelImageRequest(requestID)
    }

    func requestResourceSize(
        for asset: PHAsset,
        completion: @escaping (String, Int64?) -> Void
    ) -> UUID? {
        let identifier = asset.localIdentifier

        if let cachedSize = resourceSizeCache[identifier] {
            completion(identifier, cachedSize)
            return nil
        }

        let resources = preferredResources(for: asset)
        guard !resources.isEmpty else {
            completion(identifier, nil)
            return nil
        }

        let requestID = UUID()
        let accumulator = ByteAccumulator()
        resourceSizeRequests[requestID] = ResourceSizeRequest(
            identifier: identifier,
            accumulator: accumulator,
            dataRequestIDs: [],
            remainingResourceCount: resources.count,
            completion: completion
        )

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        for resource in resources {
            let dataRequestID = resourceManager.requestData(
                for: resource,
                options: options
            ) { data in
                accumulator.add(data.count)
            } completionHandler: { [weak self] error in
                Task { @MainActor in
                    self?.finishResource(
                        for: requestID,
                        encounteredError: error != nil
                    )
                }
            }
            resourceSizeRequests[requestID]?.dataRequestIDs.append(dataRequestID)
        }

        return requestID
    }

    func cancelResourceSizeRequest(_ requestID: UUID?) {
        guard let requestID,
              let request = resourceSizeRequests.removeValue(forKey: requestID)
        else {
            return
        }

        for dataRequestID in request.dataRequestIDs {
            resourceManager.cancelDataRequest(dataRequestID)
        }
    }

    private func preferredResources(for asset: PHAsset) -> [PHAssetResource] {
        let resources = PHAssetResource.assetResources(for: asset)

        if asset.mediaSubtypes.contains(.photoLive) {
            if let photo = resources.first(where: { $0.type == .fullSizePhoto }),
               let video = resources.first(where: { $0.type == .fullSizePairedVideo }) {
                return [photo, video]
            }

            guard let photo = resources.first(where: { $0.type == .photo }),
                  let video = resources.first(where: { $0.type == .pairedVideo })
            else {
                return []
            }
            return [photo, video]
        }

        switch asset.mediaType {
        case .image:
            return [resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo })].compactMap { $0 }
        case .video:
            return [resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video })].compactMap { $0 }
        default:
            return []
        }
    }

    private func finishResource(for requestID: UUID, encounteredError: Bool) {
        guard var request = resourceSizeRequests[requestID] else {
            return
        }

        request.encounteredError = request.encounteredError || encounteredError
        request.remainingResourceCount -= 1

        guard request.remainingResourceCount == 0 else {
            resourceSizeRequests[requestID] = request
            return
        }

        resourceSizeRequests.removeValue(forKey: requestID)
        let size = request.encounteredError ? nil : request.accumulator.value()
        if let size {
            resourceSizeCache[request.identifier] = size
        }
        request.completion(request.identifier, size)
    }

    private func previewRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return options
    }
}
