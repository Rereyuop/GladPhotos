import Foundation

enum ExternalMediaType: String, Codable, Hashable, Sendable {
    case image
    case video
    case livePhoto
}

struct ExternalMediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    let pairedVideoURL: URL?
    let mediaType: ExternalMediaType
    let fileSize: Int64?
    let creationDate: Date?
    let modificationDate: Date?
    let duration: TimeInterval?
    let pixelWidth: Int?
    let pixelHeight: Int?

    nonisolated var id: URL { url }
    nonisolated var filename: String { url.lastPathComponent }
    nonisolated var displayDate: Date? { creationDate ?? modificationDate }
    nonisolated var isLivePhoto: Bool { mediaType == .livePhoto }
    nonisolated var pixelAspectRatio: CGFloat? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }
    nonisolated var sourceURLs: [URL] {
        if let pairedVideoURL {
            return [url, pairedVideoURL]
        }
        return [url]
    }
}
