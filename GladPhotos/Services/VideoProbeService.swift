import Foundation

struct VideoProbeService: Sendable {
    func metadata(for fileURL: URL) async throws -> VideoSourceMetadata {
        let data = try await FFprobeRunner().run(for: fileURL)
        return try FFprobeJSONParser().parse(data)
    }

    func defaultTargetVideoBitrateKbps(for metadata: VideoSourceMetadata) -> Int {
        guard let bitrate = metadata.video?.bitrate, bitrate > 0 else {
            return 4_000
        }
        return min(Int((bitrate / 1_000).rounded()), 4_000)
    }

    func estimatedOutputSize(
        targetVideoBitrateKbps: Int,
        duration: TimeInterval,
        metadata: VideoSourceMetadata
    ) -> VideoCompressionEstimate {
        let videoBytes = Double(targetVideoBitrateKbps) * 1_000 * duration / 8
        let audioBitrate = metadata.audioTracks.reduce(0.0) { partial, track in
            partial + (track.bitrate ?? 0)
        }
        let audioBytes = audioBitrate * duration / 8
        return VideoCompressionEstimate(
            bytes: (videoBytes + audioBytes) * 1.02,
            includesAudio: metadata.audioTracks.isEmpty || metadata.audioTracks.allSatisfy { $0.bitrate != nil }
        )
    }
}
