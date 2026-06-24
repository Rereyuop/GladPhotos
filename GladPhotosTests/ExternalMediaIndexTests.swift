import AppKit
import ImageIO
import SQLite3
import UniformTypeIdentifiers
import XCTest
@testable import GladPhotos

final class ExternalMediaIndexTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    private var cleanupFolderIDs: [UUID] = []

    override func tearDown() async throws {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        for folderID in cleanupFolderIDs {
            try? await ExternalMediaIndexStore(folderID: folderID).reset()
        }
        cleanupURLs.removeAll()
        cleanupFolderIDs.removeAll()
        try await super.tearDown()
    }

    func testFirstScanBuildsIndex() async throws {
        let folder = try makeFolder()
        try makeImage(in: folder, name: "first.jpg")
        let folderID = makeFolderID()

        let items = try await ExternalMediaScanner().scan(folderID: folderID, folderURL: folder)
        let snapshot = try await ExternalMediaIndexStore(folderID: folderID).loadSnapshot()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(snapshot?.items.count, 1)
        XCTAssertEqual(snapshot?.items.first?.stableMediaID, items.first?.stableMediaID)
        XCTAssertGreaterThan(snapshot?.databaseSizeBytes ?? 0, 0)
    }

    func testSecondLaunchRestoresFromIndex() async throws {
        let folder = try makeFolder()
        try makeImage(in: folder, name: "restore.jpg")
        let folderID = makeFolderID()
        let first = try await ExternalMediaScanner().scan(folderID: folderID, folderURL: folder)

        let restored = await ExternalMediaScanner().indexedItems(folderID: folderID, folderURL: folder)

        XCTAssertEqual(restored?.items.map(\.stableMediaID), first.map(\.stableMediaID))
    }

    func testAddedImageIsIndexedIncrementally() async throws {
        let folder = try makeFolder()
        try makeImage(in: folder, name: "a.jpg")
        let folderID = makeFolderID()
        let scanner = ExternalMediaScanner()
        _ = try await scanner.scan(folderID: folderID, folderURL: folder)
        try makeImage(in: folder, name: "b.jpg")

        let items = try await scanner.scan(folderID: folderID, folderURL: folder)
        let snapshot = try await ExternalMediaIndexStore(folderID: folderID).loadSnapshot()

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(snapshot?.items.count, 2)
    }

    func testDeletedImageIsRemovedFromIndex() async throws {
        let folder = try makeFolder()
        let deleted = try makeImage(in: folder, name: "delete.jpg")
        try makeImage(in: folder, name: "keep.jpg")
        let folderID = makeFolderID()
        let scanner = ExternalMediaScanner()
        _ = try await scanner.scan(folderID: folderID, folderURL: folder)
        try FileManager.default.removeItem(at: deleted)

        let items = try await scanner.scan(folderID: folderID, folderURL: folder)
        let snapshot = try await ExternalMediaIndexStore(folderID: folderID).loadSnapshot()

        XCTAssertEqual(items.map(\.filename), ["keep.jpg"])
        XCTAssertEqual(snapshot?.items.map(\.filename), ["keep.jpg"])
    }

    func testModifiedImageUpdatesIndex() async throws {
        let folder = try makeFolder()
        let image = try makeImage(in: folder, name: "modify.jpg", width: 64, height: 48)
        let folderID = makeFolderID()
        let scanner = ExternalMediaScanner()
        let first = try await scanner.scan(folderID: folderID, folderURL: folder)
        try makeImage(at: image, width: 120, height: 80)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: image.path
        )

        let second = try await scanner.scan(folderID: folderID, folderURL: folder)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.pixelWidth, 120)
        XCTAssertEqual(second.first?.pixelHeight, 80)
    }

    func testRenameKeepsStableIdentifierWhenResourceIdentifierIsAvailable() async throws {
        let folder = try makeFolder()
        let originalURL = try makeImage(in: folder, name: "before.jpg")
        let renamedURL = folder.appendingPathComponent("after.jpg")
        let folderID = makeFolderID()
        let scanner = ExternalMediaScanner()
        let first = try await scanner.scan(folderID: folderID, folderURL: folder)

        try FileManager.default.moveItem(at: originalURL, to: renamedURL)
        let second = try await scanner.scan(folderID: folderID, folderURL: folder)

        XCTAssertEqual(second.first?.filename, "after.jpg")
        if first.first?.fileResourceIdentifier != nil {
            XCTAssertEqual(second.first?.stableMediaID, first.first?.stableMediaID)
        }
    }

    func testCorruptDatabaseIsRebuiltSafely() async throws {
        let folder = try makeFolder()
        try makeImage(in: folder, name: "healthy.jpg")
        let folderID = makeFolderID()
        let store = ExternalMediaIndexStore(folderID: folderID)
        try await store.reset()
        try Data("not a sqlite database".utf8).write(to: store.url)

        let restored = await ExternalMediaScanner().indexedItems(folderID: folderID, folderURL: folder)
        let rebuilt = try await ExternalMediaScanner().scan(folderID: folderID, folderURL: folder)
        let snapshot = try await store.loadSnapshot()

        XCTAssertNil(restored)
        XCTAssertEqual(rebuilt.count, 1)
        XCTAssertEqual(snapshot?.items.count, 1)
    }

    func testSchemaVersionZeroIsUpgraded() async throws {
        let folderID = makeFolderID()
        let store = ExternalMediaIndexStore(folderID: folderID)
        let item = ExternalMediaItem(
            url: URL(fileURLWithPath: "/tmp/schema.jpg"),
            pairedVideoURL: nil,
            mediaType: .image,
            fileSize: 1,
            creationDate: nil,
            modificationDate: nil,
            duration: nil,
            pixelWidth: 1,
            pixelHeight: 1
        )
        try await store.replaceAll(with: [item])
        try updateSchemaVersion(0, databaseURL: store.url)

        let snapshot = try await store.loadSnapshot()

        XCTAssertEqual(snapshot?.state, .upgraded(0, ExternalMediaIndexStore.currentSchemaVersion))
        XCTAssertEqual(snapshot?.items.count, 1)
    }

    func testOfflineFolderCanRestoreIndexAndValidateAfterReconnect() async throws {
        let folder = try makeFolder()
        try makeImage(in: folder, name: "offline.jpg")
        let offlineURL = folder.deletingLastPathComponent()
            .appendingPathComponent(folder.lastPathComponent + "-offline")
        let folderID = makeFolderID()
        _ = try await ExternalMediaScanner().scan(folderID: folderID, folderURL: folder)
        try FileManager.default.moveItem(at: folder, to: offlineURL)
        cleanupURLs.append(offlineURL)

        let restored = await ExternalMediaScanner().indexedItems(folderID: folderID, folderURL: folder)
        do {
            _ = try await ExternalMediaScanner().scan(folderID: folderID, folderURL: folder)
            XCTFail("Scan should fail while the folder is offline.")
        } catch {
        }
        try FileManager.default.moveItem(at: offlineURL, to: folder)

        let reconnected = try await ExternalMediaScanner().scan(folderID: folderID, folderURL: folder)

        XCTAssertEqual(restored?.items.count, 1)
        XCTAssertEqual(reconnected.count, 1)
    }

    private func makeFolderID() -> UUID {
        let id = UUID()
        cleanupFolderIDs.append(id)
        return id
    }

    private func makeFolder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GladPhotosIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cleanupURLs.append(folder)
        return folder
    }

    @discardableResult
    private func makeImage(
        in folder: URL,
        name: String,
        width: Int = 32,
        height: Int = 24
    ) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try makeImage(at: url, width: width, height: height)
        return url
    }

    private func makeImage(at url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(NSColor.systemPink.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func updateSchemaVersion(_ version: Int, databaseURL: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "UPDATE metadata SET value='\(version)' WHERE key='schemaVersion'",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
    }
}
