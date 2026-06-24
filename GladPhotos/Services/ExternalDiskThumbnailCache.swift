import AppKit
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

struct ExternalDiskThumbnailStats: Sendable {
    var diskExactHits = 0
    var diskLargerHits = 0
    var diskSmallerHits = 0
    var diskMisses = 0
    var diskReadFailures = 0
    var diskWrites = 0
    var diskWriteFailures = 0
    var sourceImageDecodes = 0
    var sourceVideoGenerations = 0
    var coalescedRequests = 0
    var diskCacheBytes: Int64 = 0
    var cleanupFreedBytes: Int64 = 0
    var coldFirstScreenDuration: Double = 0
    var warmFirstScreenDuration: Double = 0

    nonisolated init(
        diskExactHits: Int = 0,
        diskLargerHits: Int = 0,
        diskSmallerHits: Int = 0,
        diskMisses: Int = 0,
        diskReadFailures: Int = 0,
        diskWrites: Int = 0,
        diskWriteFailures: Int = 0,
        sourceImageDecodes: Int = 0,
        sourceVideoGenerations: Int = 0,
        coalescedRequests: Int = 0,
        diskCacheBytes: Int64 = 0,
        cleanupFreedBytes: Int64 = 0,
        coldFirstScreenDuration: Double = 0,
        warmFirstScreenDuration: Double = 0
    ) {
        self.diskExactHits = diskExactHits
        self.diskLargerHits = diskLargerHits
        self.diskSmallerHits = diskSmallerHits
        self.diskMisses = diskMisses
        self.diskReadFailures = diskReadFailures
        self.diskWrites = diskWrites
        self.diskWriteFailures = diskWriteFailures
        self.sourceImageDecodes = sourceImageDecodes
        self.sourceVideoGenerations = sourceVideoGenerations
        self.coalescedRequests = coalescedRequests
        self.diskCacheBytes = diskCacheBytes
        self.cleanupFreedBytes = cleanupFreedBytes
        self.coldFirstScreenDuration = coldFirstScreenDuration
        self.warmFirstScreenDuration = warmFirstScreenDuration
    }

    var summary: String {
        "diskExactHits=\(diskExactHits) diskLargerHits=\(diskLargerHits) diskSmallerHits=\(diskSmallerHits) diskMisses=\(diskMisses) diskReadFailures=\(diskReadFailures) diskWrites=\(diskWrites) diskWriteFailures=\(diskWriteFailures) sourceImageDecodes=\(sourceImageDecodes) sourceVideoGenerations=\(sourceVideoGenerations) coalescedRequests=\(coalescedRequests) diskCacheBytes=\(diskCacheBytes) cleanupFreedBytes=\(cleanupFreedBytes) coldFirstScreenDuration=\(coldFirstScreenDuration) warmFirstScreenDuration=\(warmFirstScreenDuration)"
    }
}

struct ExternalDiskThumbnailKey: Hashable, Sendable {
    static let renderingVersion = 1

    let stableMediaID: String
    let sourceVersion: String
    let fileSize: Int64
    let tier: ThumbnailTier
    let mediaKind: ExternalMediaType
    let renderingVersion: Int

    init(item: ExternalMediaItem, tier: ThumbnailTier, renderingVersion: Int = Self.renderingVersion) {
        self.stableMediaID = item.stableMediaID
        self.sourceVersion = "\(Self.modificationNanoseconds(item.modificationDate))"
        self.fileSize = item.fileSize ?? -1
        self.tier = tier
        self.mediaKind = item.mediaType
        self.renderingVersion = renderingVersion
    }

    nonisolated var cacheKey: String {
        [
            stableMediaID,
            sourceVersion,
            "\(fileSize)",
            "\(tier.pixels)",
            mediaKind.rawValue,
            "\(renderingVersion)"
        ].joined(separator: "|")
    }

    nonisolated var hashedFilenameStem: String {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func modificationNanoseconds(_ date: Date?) -> Int64 {
        guard let date else { return 0 }
        return Int64((date.timeIntervalSinceReferenceDate * 1_000_000_000).rounded())
    }
}

struct ExternalDiskThumbnailRead: Sendable {
    enum Match: Sendable {
        case exact
        case larger
        case smaller
    }

    let image: NSImage
    let tier: ThumbnailTier
    let match: Match
}

enum ExternalDiskThumbnailLookupPolicy: Sendable {
    case exactLargerAndSmaller
    case exactAndLarger
}

actor ExternalDiskThumbnailCache {
    static let shared = ExternalDiskThumbnailCache()

    private struct Entry {
        let cacheKey: String
        let stableMediaID: String
        let tier: Int
        let mediaKind: String
        let relativePath: String
        let byteSize: Int64
        let lastAccess: Double
        let sourceVersion: String
        let fileSize: Int64
        let renderingVersion: Int
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let databaseURL: URL
    private var database: OpaquePointer?
    private var stats = ExternalDiskThumbnailStats()
    private var pendingAccessUpdates: [String: Date] = [:]
    private var protectedPaths = Set<String>()
    private var flushTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private let byteLimit: Int64
    private let cleanupTargetBytes: Int64

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        byteLimit: Int64 = 2 * 1024 * 1024 * 1024,
        cleanupTargetBytes: Int64 = Int64(Double(2 * 1024 * 1024 * 1024) * 0.8)
    ) {
        self.fileManager = fileManager
        let cacheRoot = rootURL ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("GladPhotos", isDirectory: true)
            .appendingPathComponent("ExternalThumbnails", isDirectory: true)
        self.rootURL = cacheRoot
        self.databaseURL = cacheRoot.appendingPathComponent("manifest.sqlite")
        self.byteLimit = byteLimit
        self.cleanupTargetBytes = cleanupTargetBytes
    }

    var url: URL { rootURL }

    func resetForTests() async {
        closeDatabase()
        try? fileManager.removeItem(at: rootURL)
        stats = ExternalDiskThumbnailStats()
        pendingAccessUpdates.removeAll()
        protectedPaths.removeAll()
        flushTask?.cancel()
        cleanupTask?.cancel()
        flushTask = nil
        cleanupTask = nil
    }

    func statistics() async -> ExternalDiskThumbnailStats {
        var snapshot = stats
        snapshot.diskCacheBytes = (try? totalCacheBytes()) ?? snapshot.diskCacheBytes
        return snapshot
    }

    func resetStatistics() {
        stats = ExternalDiskThumbnailStats(diskCacheBytes: (try? totalCacheBytes()) ?? 0)
    }

    func recordSourceImageDecode() {
        stats.sourceImageDecodes += 1
    }

    func recordSourceVideoGeneration() {
        stats.sourceVideoGenerations += 1
    }

    func recordCoalescedRequest() {
        stats.coalescedRequests += 1
    }

    func cachedThumbnail(
        for key: ExternalDiskThumbnailKey,
        policy: ExternalDiskThumbnailLookupPolicy = .exactLargerAndSmaller
    ) async -> ExternalDiskThumbnailRead? {
        do {
            try openIfNeeded()
            if let exact = try entry(cacheKey: key.cacheKey) {
                return await read(entry: exact, requestedTier: key.tier, match: .exact)
            }

            if let larger = try bestEntry(
                for: key,
                comparison: "tier > ?",
                order: "tier ASC"
            ) {
                return await read(entry: larger, requestedTier: key.tier, match: .larger)
            }

            switch policy {
            case .exactLargerAndSmaller:
                if let smaller = try bestEntry(
                    for: key,
                    comparison: "tier < ?",
                    order: "tier DESC"
                ) {
                    return await read(entry: smaller, requestedTier: key.tier, match: .smaller)
                }
            case .exactAndLarger:
                break
            }

            stats.diskMisses += 1
            return nil
        } catch {
            stats.diskReadFailures += 1
            return nil
        }
    }

    func store(_ image: NSImage, for key: ExternalDiskThumbnailKey) async {
        do {
            try openIfNeeded()
            guard let payload = encodedThumbnailData(image) else {
                stats.diskWriteFailures += 1
                return
            }
            let extensionName = payload.fileExtension
            let relativePath = "\(key.hashedFilenameStem).\(extensionName)"
            let destinationURL = rootURL.appendingPathComponent(relativePath)
            let temporaryURL = rootURL.appendingPathComponent("\(relativePath).tmp-\(UUID().uuidString)")
            protectedPaths.insert(relativePath)
            defer { protectedPaths.remove(relativePath) }
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try payload.data.write(to: temporaryURL, options: [.withoutOverwriting])
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
            let byteSize = Int64(payload.data.count)
            try upsert(
                key: key,
                relativePath: relativePath,
                byteSize: byteSize
            )
            stats.diskWrites += 1
            stats.diskCacheBytes = (try? totalCacheBytes()) ?? stats.diskCacheBytes
            scheduleCleanupIfNeeded()
        } catch {
            stats.diskWriteFailures += 1
        }
    }

    func removeAll() async {
        closeDatabase()
        try? fileManager.removeItem(at: rootURL)
        stats.diskCacheBytes = 0
    }

    func cleanupNowForTests() async {
        cleanupIfNeeded()
    }

    func relativePathForTests(cacheKey: String) async -> String? {
        do {
            try openIfNeeded()
            return try entry(cacheKey: cacheKey)?.relativePath
        } catch {
            return nil
        }
    }

    func manifestColumnsForTests() async -> [String] {
        do {
            try openIfNeeded()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(thumbnails)", -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            var columns: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let column = text(at: 1, in: statement) {
                    columns.append(column)
                }
            }
            return columns
        } catch {
            return []
        }
    }

    private func read(
        entry: Entry,
        requestedTier _: ThumbnailTier,
        match: ExternalDiskThumbnailRead.Match
    ) async -> ExternalDiskThumbnailRead? {
        let url = rootURL.appendingPathComponent(entry.relativePath)
        protectedPaths.insert(entry.relativePath)
        defer { protectedPaths.remove(entry.relativePath) }
        guard let image = NSImage(contentsOf: url) else {
            stats.diskReadFailures += 1
            try? deleteEntry(cacheKey: entry.cacheKey, relativePath: entry.relativePath)
            return nil
        }
        switch match {
        case .exact: stats.diskExactHits += 1
        case .larger: stats.diskLargerHits += 1
        case .smaller: stats.diskSmallerHits += 1
        }
        pendingAccessUpdates[entry.cacheKey] = Date()
        scheduleAccessFlush()
        return ExternalDiskThumbnailRead(
            image: image,
            tier: ThumbnailTier.fitting(CGFloat(entry.tier)),
            match: match
        )
    }

    private func openIfNeeded() throws {
        if database != nil {
            if fileManager.fileExists(atPath: rootURL.path) {
                return
            }
            closeDatabase()
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
            throw SQLiteFailure.open
        }
        do {
            try execute("""
                CREATE TABLE IF NOT EXISTS thumbnails (
                    cacheKey TEXT PRIMARY KEY NOT NULL,
                    stableMediaID TEXT NOT NULL,
                    tier INTEGER NOT NULL,
                    mediaKind TEXT NOT NULL,
                    relativePath TEXT NOT NULL,
                    byteSize INTEGER NOT NULL,
                    lastAccess REAL NOT NULL,
                    sourceVersion TEXT NOT NULL,
                    fileSize INTEGER NOT NULL,
                    renderingVersion INTEGER NOT NULL
                );
                PRAGMA user_version = 2;
                CREATE INDEX IF NOT EXISTS idx_thumbnails_lookup
                ON thumbnails(stableMediaID, sourceVersion, fileSize, mediaKind, renderingVersion, tier);
                CREATE INDEX IF NOT EXISTS idx_thumbnails_lru
                ON thumbnails(lastAccess);
                """)
            try migrateIfNeeded()
        } catch {
            closeDatabase()
            try? fileManager.removeItem(at: databaseURL)
            if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
                throw SQLiteFailure.open
            }
            try execute("""
                CREATE TABLE IF NOT EXISTS thumbnails (
                    cacheKey TEXT PRIMARY KEY NOT NULL,
                    stableMediaID TEXT NOT NULL,
                    tier INTEGER NOT NULL,
                    mediaKind TEXT NOT NULL,
                    relativePath TEXT NOT NULL,
                    byteSize INTEGER NOT NULL,
                    lastAccess REAL NOT NULL,
                    sourceVersion TEXT NOT NULL,
                    fileSize INTEGER NOT NULL,
                    renderingVersion INTEGER NOT NULL
                );
                PRAGMA user_version = 2;
                CREATE INDEX IF NOT EXISTS idx_thumbnails_lookup
                ON thumbnails(stableMediaID, sourceVersion, fileSize, mediaKind, renderingVersion, tier);
                CREATE INDEX IF NOT EXISTS idx_thumbnails_lru
                ON thumbnails(lastAccess);
                """)
        }
    }

    private func closeDatabase() {
        if let database {
            sqlite3_close(database)
        }
        database = nil
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteFailure.exec
        }
    }

    private func migrateIfNeeded() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(thumbnails)", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteFailure.prepare
        }
        defer { sqlite3_finalize(statement) }
        var hasFileSize = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(at: 1, in: statement) == "fileSize" {
                hasFileSize = true
                break
            }
        }
        guard !hasFileSize else { return }
        try execute("ALTER TABLE thumbnails ADD COLUMN fileSize INTEGER NOT NULL DEFAULT -1")
        try execute("PRAGMA user_version = 2")
    }

    private func entry(cacheKey: String) throws -> Entry? {
        try queryOne(
            sql: """
            SELECT cacheKey, stableMediaID, tier, mediaKind, relativePath, byteSize, lastAccess, sourceVersion, fileSize, renderingVersion
            FROM thumbnails WHERE cacheKey = ? LIMIT 1
            """,
            bindings: [cacheKey]
        )
    }

    private func bestEntry(
        for key: ExternalDiskThumbnailKey,
        comparison: String,
        order: String
    ) throws -> Entry? {
        try queryOne(
            sql: """
            SELECT cacheKey, stableMediaID, tier, mediaKind, relativePath, byteSize, lastAccess, sourceVersion, fileSize, renderingVersion
            FROM thumbnails
            WHERE stableMediaID = ?
              AND sourceVersion = ?
              AND fileSize = ?
              AND mediaKind = ?
              AND renderingVersion = ?
              AND \(comparison)
            ORDER BY \(order)
            LIMIT 1
            """,
            bindings: [
                key.stableMediaID,
                key.sourceVersion,
                key.fileSize,
                key.mediaKind.rawValue,
                key.renderingVersion,
                key.tier.pixels
            ]
        )
    }

    private func queryOne(sql: String, bindings: [Any]) throws -> Entry? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteFailure.prepare
        }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Entry(
            cacheKey: text(at: 0, in: statement) ?? "",
            stableMediaID: text(at: 1, in: statement) ?? "",
            tier: int(at: 2, in: statement) ?? 0,
            mediaKind: text(at: 3, in: statement) ?? "",
            relativePath: text(at: 4, in: statement) ?? "",
            byteSize: int64(at: 5, in: statement) ?? 0,
            lastAccess: double(at: 6, in: statement) ?? 0,
            sourceVersion: text(at: 7, in: statement) ?? "",
            fileSize: int64(at: 8, in: statement) ?? -1,
            renderingVersion: int(at: 9, in: statement) ?? 0
        )
    }

    private func upsert(
        key: ExternalDiskThumbnailKey,
        relativePath: String,
        byteSize: Int64
    ) throws {
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO thumbnails (
            cacheKey, stableMediaID, tier, mediaKind, relativePath, byteSize, lastAccess, sourceVersion, fileSize, renderingVersion
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cacheKey) DO UPDATE SET
            relativePath = excluded.relativePath,
            byteSize = excluded.byteSize,
            lastAccess = excluded.lastAccess
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteFailure.prepare
        }
        defer { sqlite3_finalize(statement) }
        bind([
            key.cacheKey,
            key.stableMediaID,
            key.tier.pixels,
            key.mediaKind.rawValue,
            relativePath,
            byteSize,
            Date().timeIntervalSinceReferenceDate,
            key.sourceVersion,
            key.fileSize,
            key.renderingVersion
        ], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteFailure.step }
    }

    private func deleteEntry(cacheKey: String, relativePath: String) throws {
        try? fileManager.removeItem(at: rootURL.appendingPathComponent(relativePath))
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM thumbnails WHERE cacheKey = ?", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteFailure.prepare
        }
        defer { sqlite3_finalize(statement) }
        bind([cacheKey], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteFailure.step }
    }

    private func scheduleAccessFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.flushAccessUpdates()
        }
    }

    private func flushAccessUpdates() {
        flushTask = nil
        guard !pendingAccessUpdates.isEmpty else { return }
        let updates = pendingAccessUpdates
        pendingAccessUpdates.removeAll()
        do {
            try openIfNeeded()
            try execute("BEGIN TRANSACTION")
            for (cacheKey, date) in updates {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "UPDATE thumbnails SET lastAccess = ? WHERE cacheKey = ?", -1, &statement, nil) == SQLITE_OK else {
                    continue
                }
                bind([date.timeIntervalSinceReferenceDate, cacheKey], to: statement)
                _ = sqlite3_step(statement)
                sqlite3_finalize(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
        }
    }

    private func scheduleCleanupIfNeeded() {
        guard cleanupTask == nil,
              ((try? totalCacheBytes()) ?? 0) > byteLimit else { return }
        cleanupTask = Task { [weak self] in
            await self?.cleanupIfNeeded()
        }
    }

    private func cleanupIfNeeded() {
        cleanupTask = nil
        do {
            try openIfNeeded()
            var total = try totalCacheBytes()
            guard total > byteLimit else { return }
            let entries = try lruEntries()
            var freed: Int64 = 0
            for entry in entries where total > cleanupTargetBytes {
                guard !protectedPaths.contains(entry.relativePath) else { continue }
                try? fileManager.removeItem(at: rootURL.appendingPathComponent(entry.relativePath))
                try? deleteEntry(cacheKey: entry.cacheKey, relativePath: entry.relativePath)
                total -= entry.byteSize
                freed += entry.byteSize
            }
            stats.cleanupFreedBytes += freed
            stats.diskCacheBytes = total
        } catch {
        }
    }

    private func totalCacheBytes() throws -> Int64 {
        try openIfNeeded()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COALESCE(SUM(byteSize), 0) FROM thumbnails", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteFailure.prepare
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func lruEntries() throws -> [Entry] {
        var statement: OpaquePointer?
        let sql = """
        SELECT cacheKey, stableMediaID, tier, mediaKind, relativePath, byteSize, lastAccess, sourceVersion, fileSize, renderingVersion
        FROM thumbnails ORDER BY lastAccess ASC
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteFailure.prepare
        }
        defer { sqlite3_finalize(statement) }
        var entries: [Entry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entries.append(Entry(
                cacheKey: text(at: 0, in: statement) ?? "",
                stableMediaID: text(at: 1, in: statement) ?? "",
                tier: int(at: 2, in: statement) ?? 0,
                mediaKind: text(at: 3, in: statement) ?? "",
                relativePath: text(at: 4, in: statement) ?? "",
                byteSize: int64(at: 5, in: statement) ?? 0,
                lastAccess: double(at: 6, in: statement) ?? 0,
                sourceVersion: text(at: 7, in: statement) ?? "",
                fileSize: int64(at: 8, in: statement) ?? -1,
                renderingVersion: int(at: 9, in: statement) ?? 0
            ))
        }
        return entries
    }
}

private enum SQLiteFailure: Error {
    case open
    case exec
    case prepare
    case step
}

private struct EncodedThumbnail {
    let data: Data
    let fileExtension: String
}

nonisolated private func encodedThumbnailData(_ image: NSImage) -> EncodedThumbnail? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
    }
    let hasAlpha = cgImage.alphaInfo == .premultipliedLast ||
        cgImage.alphaInfo == .premultipliedFirst ||
        cgImage.alphaInfo == .last ||
        cgImage.alphaInfo == .first
    let data = NSMutableData()
    let type = hasAlpha ? UTType.png.identifier : UTType.jpeg.identifier
    guard let destination = CGImageDestinationCreateWithData(
        data,
        type as CFString,
        1,
        nil
    ) else { return nil }
    let options: [CFString: Any] = hasAlpha
        ? [:]
        : [kCGImageDestinationLossyCompressionQuality: 0.85]
    CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return EncodedThumbnail(
        data: data as Data,
        fileExtension: hasAlpha ? "png" : "jpg"
    )
}

nonisolated private func bind(_ values: [Any], to statement: OpaquePointer?) {
    for (offset, value) in values.enumerated() {
        let index = Int32(offset + 1)
        switch value {
        case let string as String:
            sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
        case let int as Int:
            sqlite3_bind_int64(statement, index, Int64(int))
        case let int64 as Int64:
            sqlite3_bind_int64(statement, index, int64)
        case let double as Double:
            sqlite3_bind_double(statement, index, double)
        default:
            sqlite3_bind_null(statement, index)
        }
    }
}

nonisolated private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated private func text(at index: Int32, in statement: OpaquePointer?) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let rawValue = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: rawValue)
}

nonisolated private func int(at index: Int32, in statement: OpaquePointer?) -> Int? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(statement, index))
}

nonisolated private func int64(at index: Int32, in statement: OpaquePointer?) -> Int64? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, index)
}

nonisolated private func double(at index: Int32, in statement: OpaquePointer?) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, index)
}
