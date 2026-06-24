import CoreML
import Foundation
import ImageIO
import Vision

struct PhotographyClassification: Sendable {
    let tag: PhotographyTag
    let confidence: Double
    let method: AnalysisMethod
    let modelVersion: String?
}

nonisolated protocol PhotographyClassifier: Sendable {
    func classify(_ item: ExternalMediaItem) async -> PhotographyClassification
}

nonisolated struct EXIFPhotographyRule: Sendable {
    func classify(properties: [CFString: Any]) -> PhotographyClassification? {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let make = string(tiff[kCGImagePropertyTIFFMake])
        let model = string(tiff[kCGImagePropertyTIFFModel])
        let shootingParameters: [CFString] = [
            kCGImagePropertyExifExposureTime,
            kCGImagePropertyExifFNumber,
            kCGImagePropertyExifISOSpeedRatings,
            kCGImagePropertyExifFocalLength,
            kCGImagePropertyExifLensModel
        ]
        let hasShootingParameter = shootingParameters.contains { exif[$0] != nil }

        guard (!make.isEmpty || !model.isEmpty), hasShootingParameter else { return nil }
        return PhotographyClassification(
            tag: .photography,
            confidence: 0.98,
            method: .exif,
            modelVersion: nil
        )
    }

    private func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

nonisolated struct FileFeatureRule: Sendable {
    private let screenshotNames = ["screenshot", "screen shot", "屏幕截图", "截屏", "屏幕快照"]
    private let exportTools = [
        "screenshot", "screen capture", "snipping tool", "snip & sketch",
        "figma", "illustrator", "canva", "sketch"
    ]
    private let commonScreenSizes: Set<String> = [
        "1170x2532", "1284x2778", "1290x2796", "1080x1920", "1440x2560",
        "1920x1080", "2560x1440", "2880x1800", "3024x1964", "3456x2234"
    ]

    func classify(url: URL, properties: [CFString: Any]) -> PhotographyClassification? {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if screenshotNames.contains(where: name.contains) {
            return nonPhotography(confidence: 0.98)
        }

        let metadataText = flattenedStrings(in: properties).joined(separator: " ").lowercased()
        if exportTools.contains(where: metadataText.contains) {
            return nonPhotography(confidence: 0.95)
        }

        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let dimensions = "\(min(width, height))x\(max(width, height))"
        if url.pathExtension.lowercased() == "png", commonScreenSizes.contains(dimensions) {
            return nonPhotography(confidence: 0.82)
        }
        return nil
    }

    private func nonPhotography(confidence: Double) -> PhotographyClassification {
        PhotographyClassification(
            tag: .nonPhotography,
            confidence: confidence,
            method: .rule,
            modelVersion: nil
        )
    }

    private func flattenedStrings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let dictionary = value as? [CFString: Any] {
            return dictionary.flatMap { [String(describing: $0.key)] + flattenedStrings(in: $0.value) }
        }
        if let array = value as? [Any] { return array.flatMap(flattenedStrings) }
        return []
    }
}

/// Replacement point for the app's future bundled Vision/Core ML model.
/// Returning nil means no model is installed; callers persist an honest unknown result.
nonisolated struct CoreMLPhotographyClassifier: Sendable {
    let modelVersion: String? = nil
    var isAvailable: Bool { false }

    func classify(thumbnail: CGImage) async -> (label: String, confidence: Double)? {
        nil
    }
}

nonisolated struct DefaultPhotographyClassifier: PhotographyClassifier {
    private let exifRule = EXIFPhotographyRule()
    private let fileRule = FileFeatureRule()
    private let model = CoreMLPhotographyClassifier()

    func classify(_ item: ExternalMediaItem) async -> PhotographyClassification {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(
                item.url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return unknown()
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] ?? [:]

        if let result = exifRule.classify(properties: properties) { return result }
        if let result = fileRule.classify(url: item.url, properties: properties) { return result }

        // Do not decode image pixels until a real model is installed. Metadata-only
        // scans should stay cheap even for large originals.
        guard model.isAvailable else { return modelUnavailableFallback() }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: 384
        ]
        guard !Task.isCancelled,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let prediction = await model.classify(thumbnail: thumbnail) else {
            return unknown()
        }
        guard prediction.confidence >= 0.65 else { return unknown(confidence: prediction.confidence) }
        return PhotographyClassification(
            tag: prediction.label == "photograph" ? .photography : .nonPhotography,
            confidence: prediction.confidence,
            method: .model,
            modelVersion: model.modelVersion
        )
    }

    private func unknown(confidence: Double = 0) -> PhotographyClassification {
        PhotographyClassification(
            tag: .unknown,
            confidence: confidence,
            method: .model,
            modelVersion: model.modelVersion
        )
    }

    private func modelUnavailableFallback() -> PhotographyClassification {
        PhotographyClassification(
            tag: .nonPhotography,
            confidence: 0,
            method: .model,
            modelVersion: nil
        )
    }
}
