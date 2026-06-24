import Foundation

struct VideoSourceMetadata: Sendable {
    let duration: TimeInterval?
    let containerBitrate: Double?
    let video: VideoStreamMetadata?
    let audioTracks: [AudioStreamMetadata]
}

struct VideoStreamMetadata: Sendable {
    let codec: String?
    let profile: String?
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let pixelFormat: String?
    let colorSpace: String?
    let colorRange: String?
    let colorPrimaries: String?
    let bitrate: Double?
}

struct AudioStreamMetadata: Identifiable, Sendable {
    let index: Int
    let codec: String?
    let channels: Int?
    let channelLayout: String?
    let sampleRate: Double?
    let bitrate: Double?
    let language: String?

    var id: Int { index }
}

struct ImageSourceMetadata: Sendable {
    let filename: String?
    let codec: String?
    let width: Int?
    let height: Int?
    let fileSize: Int64?
    let creationDate: Date?
}

