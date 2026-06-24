import AppKit
import Combine
import Photos

@MainActor
final class ExternalLivePhotoLoader: ObservableObject {
    @Published private(set) var livePhoto: PHLivePhoto?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var requestID: PHLivePhotoRequestID = PHLivePhotoRequestIDInvalid
    private var requestGeneration = 0

    func load(imageURL: URL, videoURL: URL, targetSize: CGSize) {
        cancel()
        livePhoto = nil
        errorMessage = nil
        isLoading = true
        requestGeneration += 1
        let generation = requestGeneration

        requestID = PHLivePhoto.request(
            withResourceFileURLs: [imageURL, videoURL],
            placeholderImage: nil,
            targetSize: targetSize,
            contentMode: .aspectFit
        ) { [weak self] livePhoto, info in
            Task { @MainActor in
                guard let self, self.requestGeneration == generation else { return }
                if (info[PHLivePhotoInfoCancelledKey] as? Bool) == true {
                    self.isLoading = false
                    self.requestID = PHLivePhotoRequestIDInvalid
                    return
                }
                if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    self.requestID = PHLivePhotoRequestIDInvalid
                    return
                }
                let isDegraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                if let livePhoto {
                    self.livePhoto = livePhoto
                } else {
                    self.errorMessage = "无法从这组原始文件加载实况照片。"
                }
                self.isLoading = false
                self.requestID = PHLivePhotoRequestIDInvalid
            }
        }
    }

    func cancel() {
        requestGeneration += 1
        if requestID != PHLivePhotoRequestIDInvalid {
            PHLivePhoto.cancelRequest(withRequestID: requestID)
        }
        requestID = PHLivePhotoRequestIDInvalid
        isLoading = false
    }

    deinit {
        if requestID != PHLivePhotoRequestIDInvalid {
            PHLivePhoto.cancelRequest(withRequestID: requestID)
        }
    }
}
