import Foundation
import Observation
import Photos

extension Error {
    var isPhotoLibraryUserCancellation: Bool {
        let error = self as NSError
        return error.domain == PHPhotosErrorDomain && error.code == 3072
    }
}

@Observable
@MainActor
final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver {
    enum AuthorizationState {
        case unknown
        case notDetermined
        case authorized
        case denied
    }

    private(set) var authorizationState: AuthorizationState = .unknown
    private(set) var assets: [PhotoAssetItem] = []
    private(set) var assetsSignature: PhotoAssetCollectionSignature = .empty
    private(set) var allAssets: [PhotoAssetItem] = []

    private var isObservingChanges = false
    private var isDeleting = false
    private var pendingLibraryChange = false
    private var currentFetchResult: PHFetchResult<PHAsset>?
    private var selectedMonth: MediaMonth?
    private var assetsByMonth: [MediaMonth: [PhotoAssetItem]] = [:]

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func checkAuthorization() async {
        updateAuthorizationState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        loadLibraryIfAuthorized()
    }

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        updateAuthorizationState(status)
        loadLibraryIfAuthorized()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            handleLibraryChange(changeInstance)
        }
    }

    private func updateAuthorizationState(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited:
            authorizationState = .authorized
        case .notDetermined:
            authorizationState = .notDetermined
        case .denied, .restricted:
            authorizationState = .denied
        @unknown default:
            authorizationState = .denied
        }
    }

    private func loadLibraryIfAuthorized() {
        guard authorizationState == .authorized else {
            setVisibleAssets([])
            allAssets = []
            return
        }

        startObservingChanges()
        refreshAssets()
    }

    private func startObservingChanges() {
        guard !isObservingChanges else {
            return
        }

        PHPhotoLibrary.shared().register(self)
        isObservingChanges = true
    }

    func applyMonthFilter(_ date: Date?) {
        selectedMonth = date.map { MediaMonth($0) }
        applyCurrentFilter()
    }

    func deleteAssets(_ items: [PhotoAssetItem]) async throws {
        let assetIDsToDelete = Set(items.map(\.localIdentifier))
        let assetsSnapshot = assets
        let allAssetsSnapshot = allAssets
        let fetchResultSnapshot = currentFetchResult
        let assetsToDelete = items.map(\.asset) as NSArray

        isDeleting = true
        pendingLibraryChange = false
        setVisibleAssets(
            assets.filter { !assetIDsToDelete.contains($0.localIdentifier) }
        )
        allAssets = allAssets.filter { !assetIDsToDelete.contains($0.localIdentifier) }
        rebuildMonthCache()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assetsToDelete)
            }

            isDeleting = false

            if pendingLibraryChange {
                pendingLibraryChange = false
                refreshAssets()
            }
        } catch {
            setVisibleAssets(assetsSnapshot)
            allAssets = allAssetsSnapshot
            rebuildMonthCache()
            currentFetchResult = fetchResultSnapshot
            isDeleting = false
            pendingLibraryChange = false
            throw error
        }
    }

    func refreshAndFindAsset(localIdentifier: String) throws -> PhotoAssetItem {
        refreshAssets()
        if let item = allAssets.first(where: { $0.localIdentifier == localIdentifier }) {
            return item
        }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetched.firstObject else {
            throw PhotoCompressionError.createdAssetUnavailable
        }
        return PhotoAssetItem(asset: asset)
    }

    private func handleLibraryChange(_ changeInstance: PHChange) {
        if isDeleting {
            pendingLibraryChange = true
            return
        }

        guard
            let currentFetchResult,
            let changeDetails = changeInstance.changeDetails(for: currentFetchResult)
        else {
            refreshAssets()
            return
        }

        self.currentFetchResult = changeDetails.fetchResultAfterChanges
        allAssets = makeAssetItems(from: changeDetails.fetchResultAfterChanges)
        rebuildMonthCache()
        applyCurrentFilter()
    }

    private func refreshAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(
                key: "creationDate",
                ascending: true
            )
        ]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )

        let fetchResult = PHAsset.fetchAssets(with: options)
        currentFetchResult = fetchResult
        allAssets = makeAssetItems(from: fetchResult)
        rebuildMonthCache()
        applyCurrentFilter()
    }

    private func makeAssetItems(from fetchResult: PHFetchResult<PHAsset>) -> [PhotoAssetItem] {
        var fetchedAssets: [PhotoAssetItem] = []
        fetchedAssets.reserveCapacity(fetchResult.count)

        fetchResult.enumerateObjects { asset, _, _ in
            fetchedAssets.append(PhotoAssetItem(asset: asset))
        }

        return fetchedAssets
    }

    private func rebuildMonthCache() {
        var cache: [MediaMonth: [PhotoAssetItem]] = [:]
        for item in allAssets {
            guard let date = item.asset.creationDate else { continue }
            cache[MediaMonth(date), default: []].append(item)
        }
        assetsByMonth = cache
    }

    private func applyCurrentFilter() {
        setVisibleAssets(selectedMonth.map { assetsByMonth[$0] ?? [] } ?? allAssets)
    }

    private func setVisibleAssets(_ newAssets: [PhotoAssetItem]) {
        assets = newAssets
        assetsSignature = PhotoAssetCollectionSignature.make(from: newAssets)
    }
}
