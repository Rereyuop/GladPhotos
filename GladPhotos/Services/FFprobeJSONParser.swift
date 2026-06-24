import Foundation

struct FFprobeJSONParser: Sendable {
    enum ParserError: LocalizedError {
        case invalidJSON
        case noMediaStreams

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "ffprobe 返回了无法解析的 JSON。"
            case .noMediaStreams:
                return "文件中没有可识别的视频或音频流。"
            }
        }
    }

    func parse(_ data: Data) throws -> VideoSourceMetadata {
        let response: ProbeResponse
        do {
            response = try JSONDecoder().decode(ProbeResponse.self, from: data)
        } catch {
            throw ParserError.invalidJSON
        }

        let videoStream = response.streams.first(where: { $0.codecType == "video" })
        let audioStreams = response.streams.filter { $0.codecType == "audio" }
        guard videoStream != nil || !audioStreams.isEmpty else {
            throw ParserError.noMediaStreams
        }

        let video = videoStream.map {
            VideoStreamMetadata(
                codec: valid($0.codecName),
                profile: valid($0.profile),
                width: positive($0.width),
                height: positive($0.height),
                frameRate: frameRate($0.avgFrameRate) ?? frameRate($0.realFrameRate),
                pixelFormat: valid($0.pixelFormat),
                colorSpace: valid($0.colorSpace),
                colorRange: valid($0.colorRange),
                colorPrimaries: valid($0.colorPrimaries),
                bitrate: positiveNumber($0.bitRate)
            )
        }

        let audioTracks = audioStreams.map {
            AudioStreamMetadata(
                index: $0.index,
                codec: valid($0.codecName),
                channels: positive($0.channels),
                channelLayout: valid($0.channelLayout),
                sampleRate: positiveNumber($0.sampleRate),
                bitrate: positiveNumber($0.bitRate),
                language: valid($0.tags?.language)
            )
        }

        return VideoSourceMetadata(
            duration: positiveNumber(response.format?.duration),
            containerBitrate: positiveNumber(response.format?.bitRate),
            video: video,
            audioTracks: audioTracks
        )
    }

    private func valid(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "n/a", trimmed != "0" else {
            return nil
        }
        return trimmed
    }

    private func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private func positiveNumber(_ value: String?) -> Double? {
        guard let value = valid(value), let number = Double(value), number > 0 else {
            return nil
        }
        return number
    }

    private func frameRate(_ value: String?) -> Double? {
        guard let value = valid(value) else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2,
           let numerator = Double(parts[0]),
           let denominator = Double(parts[1]),
           denominator != 0 {
            let result = numerator / denominator
            return result > 0 ? result : nil
        }
        return positiveNumber(value)
    }
}

private struct ProbeResponse: Decodable {
    let streams: [ProbeStream]
    let format: ProbeFormat?
}

private struct ProbeFormat: Decodable {
    let duration: String?
    let bitRate: String?

    enum CodingKeys: String, CodingKey {
        case duration
        case bitRate = "bit_rate"
    }
}

private struct ProbeStream: Decodable {
    let index: Int
    let codecType: String?
    let codecName: String?
    let profile: String?
    let width: Int?
    let height: Int?
    let avgFrameRate: String?
    let realFrameRate: String?
    let pixelFormat: String?
    let colorSpace: String?
    let colorRange: String?
    let colorPrimaries: String?
    let bitRate: String?
    let channels: Int?
    let channelLayout: String?
    let sampleRate: String?
    let tags: ProbeTags?

    enum CodingKeys: String, CodingKey {
        case index, profile, width, height, channels, tags
        case codecType = "codec_type"
        case codecName = "codec_name"
        case avgFrameRate = "avg_frame_rate"
        case realFrameRate = "r_frame_rate"
        case pixelFormat = "pix_fmt"
        case colorSpace = "color_space"
        case colorRange = "color_range"
        case colorPrimaries = "color_primaries"
        case bitRate = "bit_rate"
        case channelLayout = "channel_layout"
        case sampleRate = "sample_rate"
    }
}

private struct ProbeTags: Decodable {
    let language: String?
}

