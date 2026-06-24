import Foundation

enum VideoCompressionRange: Equatable, Sendable {
    case fullVideo
    case clip(start: TimeInterval, end: TimeInterval)

    func processingDuration(totalDuration: TimeInterval) -> TimeInterval? {
        switch self {
        case .fullVideo:
            guard totalDuration.isFinite, totalDuration > 0 else { return nil }
            return totalDuration
        case let .clip(start, end):
            guard start.isFinite, end.isFinite,
                  start >= 0,
                  end > start,
                  end <= totalDuration
            else { return nil }
            return end - start
        }
    }
}

struct VideoCompressionRequest: Sendable {
    let inputURL: URL
    let outputURL: URL
    let range: VideoCompressionRange
    let targetVideoBitrateKbps: Int
}

struct VideoCompressionProgress: Sendable {
    let fraction: Double
    let elapsed: TimeInterval
    let speed: String?
}

struct VideoCompressionEstimate: Sendable {
    let bytes: Double
    let includesAudio: Bool
}
