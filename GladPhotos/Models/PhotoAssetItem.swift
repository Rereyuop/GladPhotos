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

struct PhotoAssetCollectionSignature: Equatable {
    static let empty = PhotoAssetCollectionSignature(count: 0, checksum: 0)

    let count: Int
    let checksum: UInt64

    static func make(from items: [PhotoAssetItem]) -> PhotoAssetCollectionSignature {
        var hasher = StableAssetHasher()

        for item in items {
            hasher.combine(item.localIdentifier)
            hasher.combine(item.asset.creationDate?.timeIntervalSince1970 ?? -1)
            hasher.combine(item.asset.modificationDate?.timeIntervalSince1970 ?? -1)
            hasher.combine(Int64(item.asset.mediaType.rawValue))
            hasher.combine(Int64(item.asset.mediaSubtypes.rawValue))
            hasher.combine(Int64(item.asset.pixelWidth))
            hasher.combine(Int64(item.asset.pixelHeight))
        }

        return PhotoAssetCollectionSignature(
            count: items.count,
            checksum: hasher.value
        )
    }
}

private struct StableAssetHasher {
    private(set) var value: UInt64 = 0xcbf29ce484222325
    private let prime: UInt64 = 0x100000001b3

    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value &*= prime
        }
    }

    mutating func combine(_ number: Int64) {
        combine(UInt64(bitPattern: number))
    }

    mutating func combine(_ number: Double) {
        combine(number.bitPattern)
    }

    private mutating func combine(_ number: UInt64) {
        var value = number
        for _ in 0..<8 {
            self.value ^= value & 0xff
            self.value &*= prime
            value >>= 8
        }
    }
}
