import AppKit
import Foundation
import Photos

enum ApplePhotosLocator {
    static let failureMessage = "无法在 Apple“照片”中定位此项目"

    static func canLocate(_ asset: PHAsset) -> Bool {
        asset.mediaType == .image || asset.mediaType == .video
    }

    @MainActor
    static func open(_ asset: PHAsset) -> Bool {
        guard canLocate(asset),
              let collection = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: .smartAlbumUserLibrary,
                options: nil
              ).firstObject,
              let url = photosURL(albumIdentifier: collection.localIdentifier, assetIdentifier: asset.localIdentifier)
        else {
            return false
        }

        let opened = NSWorkspace.shared.open(url)

        #if DEBUG
        print("DEBUG ApplePhotosLocator albumIdentifier=\(collection.localIdentifier)")
        print("DEBUG ApplePhotosLocator assetIdentifier=\(asset.localIdentifier)")
        print("DEBUG ApplePhotosLocator url=\(url.absoluteString)")
        print("DEBUG ApplePhotosLocator openReturned=\(opened)")
        #endif

        return opened
    }

    private static func photosURL(albumIdentifier: String, assetIdentifier: String) -> URL? {
        let albumUUID = uuidPrefix(from: albumIdentifier)
        let assetUUID = uuidPrefix(from: assetIdentifier)

        guard !albumUUID.isEmpty, !assetUUID.isEmpty else {
            return nil
        }

        // This Photos URL scheme is undocumented and may stop working on a future macOS release.
        return URL(string: "photos:albums?albumUuid=\(albumUUID)&assetUuid=\(assetUUID)")
    }

    private static func uuidPrefix(from localIdentifier: String) -> String {
        String(localIdentifier.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}
