import Foundation

@MainActor
final class VideoCompressionService {
    enum CompressionError: LocalizedError {
        case invalidRange
        case invalidBitrate
        case originalOverwrite
        case outputExists
        case incompatibleAudioForMP4

        var errorDescription: String? {
            switch self {
            case .invalidRange:
                return "压缩时间范围无效。"
            case .invalidBitrate:
                return "目标视频码率必须是合理的正整数。"
            case .originalOverwrite:
                return "不能覆盖原视频。"
            case .outputExists:
                return "目标文件已存在。"
            case .incompatibleAudioForMP4:
                return "原视频音频格式无法在不重新编码的情况下写入 MP4。"
            }
        }
    }

    private let probeService = VideoProbeService()
    private let resolver = FFmpegExecutableResolver()
    private let runner = FFmpegProcessRunner()
    private var partialURL: URL?

    func compress(
        request: VideoCompressionRequest,
        totalDuration: TimeInterval,
        progressHandler: @escaping @MainActor (VideoCompressionProgress) -> Void
    ) async throws {
        guard request.targetVideoBitrateKbps > 0, request.targetVideoBitrateKbps <= 500_000 else {
            throw CompressionError.invalidBitrate
        }
        guard let processingDuration = request.range.processingDuration(totalDuration: totalDuration) else {
            throw CompressionError.invalidRange
        }
        guard request.outputURL.standardizedFileURL != request.inputURL.standardizedFileURL else {
            throw CompressionError.originalOverwrite
        }
        guard !FileManager.default.fileExists(atPath: request.outputURL.path) else {
            throw CompressionError.outputExists
        }

        let outputDirectory = request.outputURL.deletingLastPathComponent()
        let didStartInputAccess = request.inputURL.startAccessingSecurityScopedResource()
        let didStartOutputAccess = outputDirectory.startAccessingSecurityScopedResource()
        defer {
            if didStartInputAccess {
                request.inputURL.stopAccessingSecurityScopedResource()
            }
            if didStartOutputAccess {
                outputDirectory.stopAccessingSecurityScopedResource()
            }
        }

        let metadata = try await probeService.metadata(for: request.inputURL)
        guard Self.audioTracksCanCopyToMP4(metadata.audioTracks) else {
            throw CompressionError.incompatibleAudioForMP4
        }

        let executableURL = try resolver.resolve()
        let partialURL = Self.partialURL(for: request.outputURL)
        self.partialURL = partialURL
        try? FileManager.default.removeItem(at: partialURL)

        do {
            let arguments = Self.arguments(
                inputURL: request.inputURL,
                partialURL: partialURL,
                range: request.range,
                targetVideoBitrateKbps: request.targetVideoBitrateKbps
            )
            try await runner.run(
                executableURL: executableURL,
                arguments: arguments,
                processingDuration: processingDuration,
                progressHandler: progressHandler
            )
            if FileManager.default.fileExists(atPath: request.outputURL.path) {
                throw CompressionError.outputExists
            }
            try FileManager.default.moveItem(at: partialURL, to: request.outputURL)
            self.partialURL = nil
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            self.partialURL = nil
            throw error
        }
    }

    func cancel() {
        runner.cancel()
        if let partialURL {
            try? FileManager.default.removeItem(at: partialURL)
        }
        partialURL = nil
    }

    static func uniqueOutputURL(
        for inputURL: URL,
        range: VideoCompressionRange,
        targetVideoBitrateKbps: Int
    ) -> URL {
        let directory = inputURL.deletingLastPathComponent()
        let base = inputURL.deletingPathExtension().lastPathComponent
        let suffix: String
        switch range {
        case .fullVideo:
            suffix = "_compressed_\(targetVideoBitrateKbps)kbps"
        case .clip:
            suffix = "_trim_\(targetVideoBitrateKbps)kbps"
        }

        var candidate = directory.appendingPathComponent("\(base)\(suffix).mp4")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)\(suffix)_\(index).mp4")
            index += 1
        }
        return candidate
    }

    static func arguments(
        inputURL: URL,
        partialURL: URL,
        range: VideoCompressionRange,
        targetVideoBitrateKbps: Int
    ) -> [String] {
        var arguments = ["-hide_banner", "-nostdin"]
        switch range {
        case .fullVideo:
            arguments += ["-i", inputURL.path]
        case let .clip(start, end):
            arguments += ["-ss", formatTimestamp(start), "-i", inputURL.path, "-t", formatTimestamp(end - start)]
        }
        let target = "\(targetVideoBitrateKbps)k"
        arguments += [
            "-map", "0:v:0",
            "-map", "0:a?",
            "-c:v", "h264_videotoolbox",
            "-b:v", target,
            "-maxrate", target,
            "-bufsize", "\(targetVideoBitrateKbps * 2)k",
            "-pix_fmt", "yuv420p",
            "-tag:v", "avc1",
            "-c:a", "copy",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            "-nostats",
            partialURL.path
        ]
        return arguments
    }

    private static func partialURL(for outputURL: URL) -> URL {
        outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).partial.mp4")
    }

    private static func formatTimestamp(_ value: TimeInterval) -> String {
        String(format: "%.3f", max(0, value))
    }

    private static func audioTracksCanCopyToMP4(_ tracks: [AudioStreamMetadata]) -> Bool {
        let compatibleCodecs: Set<String> = ["aac", "mp3", "alac", "ac3", "eac3"]
        return tracks.allSatisfy { track in
            guard let codec = track.codec?.lowercased() else { return false }
            return compatibleCodecs.contains(codec)
        }
    }
}
