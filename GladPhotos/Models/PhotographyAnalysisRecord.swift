import Foundation

nonisolated enum PhotographyTag: String, Codable, CaseIterable, Hashable, Sendable {
    case photography
    case nonPhotography
    case unknown

    var title: String {
        switch self {
        case .photography: "摄影"
        case .nonPhotography: "非摄影"
        case .unknown: "未识别"
        }
    }
}

nonisolated enum AnalysisMethod: String, Codable, Hashable, Sendable {
    case exif
    case rule
    case model
    case manual
}

nonisolated struct PhotographyAnalysisRecord: Codable, Hashable, Sendable {
    let filePath: String
    let fileSize: Int64?
    let modificationDate: Date?
    let resourceIdentifier: String
    var predictedTag: PhotographyTag
    var confidence: Double
    var manualTag: PhotographyTag?
    var analysisMethod: AnalysisMethod
    var modelVersion: String?
    var analyzedAt: Date?

    var effectiveTag: PhotographyTag { manualTag ?? predictedTag }
    var isManual: Bool { manualTag != nil }
    var effectiveAnalysisMethod: AnalysisMethod {
        manualTag == nil ? analysisMethod : .manual
    }

    nonisolated func matches(_ item: ExternalMediaItem) -> Bool {
        filePath == item.url.standardizedFileURL.path
            && fileSize == item.fileSize
            && modificationDate == item.modificationDate
    }
}

nonisolated enum PhotographyFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case photography
    case nonPhotography
    case unknown

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部"
        case .photography: "摄影"
        case .nonPhotography: "非摄影"
        case .unknown: "未识别"
        }
    }

    func includes(_ tag: PhotographyTag) -> Bool {
        switch self {
        case .all: true
        case .photography: tag == .photography
        case .nonPhotography: tag == .nonPhotography
        case .unknown: tag == .unknown
        }
    }
}
