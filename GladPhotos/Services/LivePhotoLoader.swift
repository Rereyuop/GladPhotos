import Combine
import Photos

@MainActor
final class LivePhotoLoader: ObservableObject {
    @Published private(set) var livePhoto: PHLivePhoto?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let imageManager = PHImageManager.default()
    private var requestID: PHImageRequestID?
    private var requestGeneration = 0

    func load(asset: PHAsset, targetSize: CGSize) {
        cancel()
        livePhoto = nil
        errorMessage = nil
        isLoading = true

        requestGeneration += 1
        let generation = requestGeneration
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        requestID = imageManager.requestLivePhoto(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] livePhoto, info in
            Task { @MainActor in
                guard let self, self.requestGeneration == generation else {
                    return
                }

                if (info?[PHImageCancelledKey] as? Bool) == true {
                    self.isLoading = false
                    self.requestID = nil
                    return
                }

                if let error = info?[PHImageErrorKey] as? Error {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    self.requestID = nil
                    return
                }

                let isDegraded =
                    (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else {
                    return
                }

                self.livePhoto = livePhoto
                if livePhoto == nil {
                    self.errorMessage = "无法加载这张实况照片。"
                }
                self.isLoading = false
                self.requestID = nil
            }
        }
    }

    func cancel() {
        requestGeneration += 1
        if let requestID {
            imageManager.cancelImageRequest(requestID)
        }
        requestID = nil
        isLoading = false
    }

    deinit {
        if let requestID {
            imageManager.cancelImageRequest(requestID)
        }
    }
}
