import Foundation

enum ExternalMediaType: String, Codable, Hashable, Sendable {
    case image
    case video
    case livePhoto
}

struct ExternalMediaItem: Identifiable, Hashable, Sendable {
    let stableMediaID: String
    let url: URL
    let normalizedPath: String
    let fileResourceIdentifier: String?
    let pairedVideoURL: URL?
    let pairedVideoStableID: String?
    let pairedVideoPath: String?
    let mediaType: ExternalMediaType
    let fileSize: Int64?
    let creationDate: Date?
    let modificationDate: Date?
    let captureDate: Date?
    let duration: TimeInterval?
    let videoDuration: TimeInterval?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let orientation: Int?
    let schemaVersion: Int

    nonisolated init(
        stableMediaID: String? = nil,
        url: URL,
        normalizedPath: String? = nil,
        fileResourceIdentifier: String? = nil,
        pairedVideoURL: URL?,
        pairedVideoStableID: String? = nil,
        pairedVideoPath: String? = nil,
        mediaType: ExternalMediaType,
        fileSize: Int64?,
        creationDate: Date?,
        modificationDate: Date?,
        captureDate: Date? = nil,
        duration: TimeInterval?,
        videoDuration: TimeInterval? = nil,
        pixelWidth: Int?,
        pixelHeight: Int?,
        orientation: Int? = nil,
        schemaVersion: Int = 1
    ) {
        let normalizedPath = normalizedPath ?? url.resolvingSymlinksInPath().standardizedFileURL.path
        self.stableMediaID = stableMediaID ?? ExternalMediaItem.fallbackStableMediaID(
            normalizedPath: normalizedPath,
            fileSize: fileSize,
            modificationDate: modificationDate
        )
        self.url = url
        self.normalizedPath = normalizedPath
        self.fileResourceIdentifier = fileResourceIdentifier
        self.pairedVideoURL = pairedVideoURL
        self.pairedVideoStableID = pairedVideoStableID
        self.pairedVideoPath = pairedVideoPath
        self.mediaType = mediaType
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.captureDate = captureDate
        self.duration = duration ?? videoDuration
        self.videoDuration = videoDuration ?? duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.schemaVersion = schemaVersion
    }

    nonisolated var id: String { stableMediaID }
    nonisolated var filename: String { url.lastPathComponent }
    nonisolated var displayDate: Date? { captureDate ?? creationDate ?? modificationDate }
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

    nonisolated private static func fallbackStableMediaID(
        normalizedPath: String,
        fileSize: Int64?,
        modificationDate: Date?
    ) -> String {
        let mtimeNs = modificationDate.map {
            Int64(($0.timeIntervalSinceReferenceDate * 1_000_000_000).rounded())
        } ?? 0
        return "path:\(normalizedPath)#size=\(fileSize ?? -1)#mtimeNs=\(mtimeNs)"
    }
}
