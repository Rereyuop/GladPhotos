import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import GladPhotos

@MainActor
final class ExternalMediaThumbnailLifecycleTests: XCTestCase {
    func testReturnVisitKeepsDisplayedImageThroughViewLifecycleChanges() async throws {
        let url = try makeTestImage()
        let modificationDate = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let item = ExternalMediaItem(
            url: url,
            pairedVideoURL: nil,
            mediaType: .image,
            fileSize: nil,
            creationDate: nil,
            modificationDate: modificationDate,
            duration: nil,
            pixelWidth: 1_600,
            pixelHeight: 1_200
        )
        let service = ExternalThumbnailService()
        let state = ThumbnailLifecycleHarnessState()

        var host: NSHostingView<ThumbnailLifecycleHarness>? = NSHostingView(
            rootView: ThumbnailLifecycleHarness(item: item, service: service, state: state)
        )
        host?.frame = CGRect(x: 0, y: 0, width: 220, height: 260)
        host?.layoutSubtreeIfNeeded()
        _ = await service.image(
            for: item,
            maxPixelSize: CGFloat(ThumbnailTier.preview.pixels),
            allowEmbeddedThumbnail: true,
            sizing: .longestEdge
        )
        _ = await service.image(
            for: item,
            maxPixelSize: CGFloat(ThumbnailTier.large.pixels),
            allowEmbeddedThumbnail: false,
            sizing: .longestEdge
        )
        let firstPassStats = service.cacheStatistics()
        XCTAssertGreaterThan(firstPassStats.decodedRequests, 0)

        host = nil
        service.resetCacheStatistics()

        let returnState = ThumbnailLifecycleHarnessState()
        let returnHost = NSHostingView(
            rootView: ThumbnailLifecycleHarness(item: item, service: service, state: returnState)
        )
        returnHost.frame = CGRect(x: 0, y: 0, width: 220, height: 260)
        returnHost.layoutSubtreeIfNeeded()
        XCTAssertFalse(containsSpinner(returnHost), "Return-visit first frame must use cached displayedImage.")

        returnState.width = 132
        returnHost.frame = CGRect(x: 0, y: 0, width: 132, height: 260)
        returnHost.layoutSubtreeIfNeeded()
        await Task.yield()
        XCTAssertFalse(containsSpinner(returnHost), "Geometry tier changes must keep the existing displayedImage.")

        returnState.finalLoadID = UUID()
        returnHost.layoutSubtreeIfNeeded()
        await Task.yield()
        XCTAssertFalse(containsSpinner(returnHost), "Final thumbnail retries must not clear displayedImage.")

        let returnStats = service.cacheStatistics()
        XCTAssertEqual(returnStats.decodedRequests, 0, "Return visit and lifecycle changes should not trigger a new decode.")
    }

    private func makeTestImage() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GladPhotosThumbnailLifecycle-\(UUID().uuidString).jpg")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1_600,
            height: 1_200,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 1_200))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImageDestinationEmbedThumbnail: true
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

}

@MainActor
private final class ThumbnailLifecycleHarnessState: ObservableObject {
    @Published var width: CGFloat = 220
    @Published var finalLoadID = UUID()
}

private struct ThumbnailLifecycleHarness: View {
    let item: ExternalMediaItem
    let service: ExternalThumbnailService
    @ObservedObject var state: ThumbnailLifecycleHarnessState

    var body: some View {
        ExternalMediaThumbnailView(
            item: item,
            thumbnailService: service,
            displayMode: .originalRatio,
            thumbnailWidth: state.width,
            showsMediaInfo: false,
            allowsFinalThumbnail: true,
            finalLoadID: state.finalLoadID
        )
        .frame(width: state.width)
    }
}

@MainActor
private func containsSpinner(_ view: NSView) -> Bool {
    if view.accessibilityIdentifier() == "ExternalMediaThumbnailSpinner" {
        return true
    }
    return view.subviews.contains { containsSpinner($0) }
}
