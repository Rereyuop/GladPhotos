import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main
struct ExternalMediaBenchmark {
    static func main() async throws {
        let counts = CommandLine.arguments.dropFirst().compactMap(Int.init)
        for count in counts.isEmpty ? [1_000, 10_000] : counts {
            try await run(count: count)
        }
    }

    private static func run(count: Int) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GladPhotosBenchmark-\(count)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seed = root.appendingPathComponent(".seed.jpg")
        try makeSeedJPEG(at: seed)

        let directoryCount = 20
        for directoryIndex in 0..<directoryCount {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("album-\(directoryIndex)"),
                withIntermediateDirectories: true
            )
        }
        for index in 0..<count {
            let destination = root
                .appendingPathComponent("album-\(index % directoryCount)")
                .appendingPathComponent(String(format: "image-%05d.jpg", index))
            try FileManager.default.linkItem(at: seed, to: destination)
        }

        let scanner = ExternalMediaScanner()
        let scanStart = ContinuousClock.now
        let items = try await scanner.scan(folderURL: root)
        let scanDuration = scanStart.duration(to: .now)

        let firstScreen = Array(items.prefix(48))
        let firstScreenStart = ContinuousClock.now
        let firstScreenDecoded = await decode(firstScreen, pixelSize: 320)
        let firstScreenDuration = firstScreenStart.duration(to: .now)

        // Scroll proxy: process successive visible windows while retaining no images.
        // The app itself uses the same decoder and cancels windows that disappear.
        let scrollSample = Array(items.prefix(min(items.count, 240)))
        let scrollStart = ContinuousClock.now
        var decodedDuringScroll = 0
        for offset in stride(from: 0, to: scrollSample.count, by: 48) {
            let end = min(offset + 48, scrollSample.count)
            decodedDuringScroll += await decode(Array(scrollSample[offset..<end]), pixelSize: 320)
        }
        let scrollDuration = scrollStart.duration(to: .now)
        let cancellationRecovery = await measureCancellationRecovery(
            items: items,
            folderURL: root,
            seedURL: seed
        )

        print("dataset=\(count) files")
        print("scan=\(format(scanDuration)) discovered=\(items.count)")
        print("first_screen=\(format(firstScreenDuration)) decoded=\(firstScreenDecoded)/\(firstScreen.count)")
        print("scroll_proxy=\(format(scrollDuration)) decoded=\(decodedDuringScroll)/\(scrollSample.count)")
        print("cancel_recovery=\(format(cancellationRecovery))")
        print(String(format: "resident_memory=%.1f MB", residentMemoryMB()))
    }

    @MainActor
    private static func measureCancellationRecovery(
        items: [ExternalMediaItem],
        folderURL: URL,
        seedURL: URL
    ) async -> Duration {
        let service = ExternalThumbnailService()
        for item in items.prefix(200) {
            Task { _ = await service.image(for: item, maxPixelSize: 320) }
        }
        await Task.yield()
        service.cancelRequests(in: folderURL)

        let recoveryURL = folderURL.deletingLastPathComponent()
            .appendingPathComponent("GladPhotosRecovery-\(UUID().uuidString).jpg")
        try? FileManager.default.linkItem(at: seedURL, to: recoveryURL)
        defer { try? FileManager.default.removeItem(at: recoveryURL) }
        let recoveryItem = ExternalMediaItem(
            url: recoveryURL,
            pairedVideoURL: nil,
            mediaType: .image,
            fileSize: nil,
            creationDate: nil,
            modificationDate: nil,
            duration: nil,
            pixelWidth: 1_600,
            pixelHeight: 1_200
        )
        let start = ContinuousClock.now
        _ = await service.image(for: recoveryItem, maxPixelSize: 320)
        return start.duration(to: .now)
    }

    private static func decode(_ items: [ExternalMediaItem], pixelSize: CGFloat) async -> Int {
        var decoded = 0
        for offset in stride(from: 0, to: items.count, by: 6) {
            let end = min(offset + 6, items.count)
            decoded += await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for item in items[offset..<end] {
                    group.addTask {
                        autoreleasepool {
                            ExternalImagePipeline.thumbnail(
                                url: item.url,
                                requestedPixelSize: Int(pixelSize),
                                preferEmbedded: true
                            ) != nil
                        }
                    }
                }
                var batchDecoded = 0
                for await succeeded in group where succeeded { batchDecoded += 1 }
                return batchDecoded
            }
        }
        return decoded
    }

    private static func makeSeedJPEG(at url: URL) throws {
        let width = 1_600
        let height = 1_200
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let image = context.makeImage(),
           let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
           ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
            kCGImageDestinationEmbedThumbnail: true
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    private static func format(_ duration: Duration) -> String {
        String(format: "%.3fs", Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18)
    }
}
