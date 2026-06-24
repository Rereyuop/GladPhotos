import Photos

struct PhotoAssetItem: Identifiable, Hashable {
    let asset: PHAsset

    var id: String {
        asset.localIdentifier
    }

    var localIdentifier: String {
        asset.localIdentifier
    }

    static func == (lhs: PhotoAssetItem, rhs: PhotoAssetItem) -> Bool {
        lhs.localIdentifier == rhs.localIdentifier
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(localIdentifier)
    }
}
