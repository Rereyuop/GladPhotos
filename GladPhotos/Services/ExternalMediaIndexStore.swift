import Foundation
import SQLite3

struct ExternalMediaIndexBenchmark: Sendable {
    var firstScanDuration: Duration?
    var indexRestoreDuration: Duration?
    var validationDuration: Duration?
    var mainThreadPublishDuration: Duration?
    var databaseSizeBytes: Int64?

    nonisolated init(
        firstScanDuration: Duration? = nil,
        indexRestoreDuration: Duration? = nil,
        validationDuration: Duration? = nil,
        mainThreadPublishDuration: Duration? = nil,
        databaseSizeBytes: Int64? = nil
    ) {
        self.firstScanDuration = firstScanDuration
        self.indexRestoreDuration = indexRestoreDuration
        self.validationDuration = validationDuration
        self.mainThreadPublishDuration = mainThreadPublishDuration
        self.databaseSizeBytes = databaseSizeBytes
    }
}

enum ExternalMediaIndexState: Sendable, Equatable {
    case missing
    case valid
    case rebuilt
    case corrupt
    case incompatibleSchema(Int)
    case upgraded(Int, Int)
}

struct ExternalMediaIndexSnapshot: Sendable {
    let items: [ExternalMediaItem]
    let state: ExternalMediaIndexState
    let databaseSizeBytes: Int64?

    nonisolated init(
        items: [ExternalMediaItem],
        state: ExternalMediaIndexState,
        databaseSizeBytes: Int64?
    ) {
        self.items = items
        self.state = state
        self.databaseSizeBytes = databaseSizeBytes
    }
}

actor ExternalMediaIndexStore {
    static let currentSchemaVersion = 1

    enum IndexError: Error {
        case corrupt
        case incompatibleSchema(Int)
        case sqlite(String)
    }

    private let folderID: UUID
    private let databaseURL: URL

    init(folderID: UUID, databaseDirectory: URL? = nil) {
        self.folderID = folderID
        let directory = databaseDirectory ?? Self.defaultDatabaseDirectory()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        databaseURL = directory.appendingPathComponent("\(folderID.uuidString).sqlite")
    }

    nonisolated var url: URL { databaseURL }

    func loadSnapshot() throws -> ExternalMediaIndexSnapshot? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let state = try ensureReadableSchema(in: database)
        let items = try selectItems(in: database)
        return ExternalMediaIndexSnapshot(
            items: items,
            state: state,
            databaseSizeBytes: databaseSize()
        )
    }

    func replaceAll(with items: [ExternalMediaItem]) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchemaIfNeeded(in: database)
        try transaction(in: database) {
            try execute("DELETE FROM media", in: database)
            for item in items {
                try upsert(item, in: database)
            }
            try setMetadata("schemaVersion", "\(Self.currentSchemaVersion)", in: database)
            try setMetadata("folderID", folderID.uuidString, in: database)
        }
    }

    func apply(upserts: [ExternalMediaItem], deletions: Set<String>) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try createSchemaIfNeeded(in: database)
        try transaction(in: database) {
            for stableMediaID in deletions {
                try delete(stableMediaID: stableMediaID, in: database)
            }
            for item in upserts {
                try upsert(item, in: database)
            }
            try setMetadata("schemaVersion", "\(Self.currentSchemaVersion)", in: database)
            try setMetadata("folderID", folderID.uuidString, in: database)
        }
    }

    func reset() throws {
        try? FileManager.default.removeItem(at: databaseURL)
    }

    func databaseSize() -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    private static func defaultDatabaseDirectory() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("GladPhotos", isDirectory: true)
            .appendingPathComponent("ExternalMediaIndex", isDirectory: true)
    }

    private func openDatabase() throws -> OpaquePointer? {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            if let database { sqlite3_close(database) }
            throw IndexError.sqlite(message)
        }
        try execute("PRAGMA journal_mode=WAL", in: database)
        try execute("PRAGMA synchronous=NORMAL", in: database)
        return database
    }

    private func ensureReadableSchema(in database: OpaquePointer?) throws -> ExternalMediaIndexState {
        guard tableExists("metadata", in: database), tableExists("media", in: database) else {
            throw IndexError.corrupt
        }
        let version = Int(try metadata("schemaVersion", in: database) ?? "") ?? 0
        if version == Self.currentSchemaVersion {
            return .valid
        }
        if version == 0 {
            try setMetadata("schemaVersion", "\(Self.currentSchemaVersion)", in: database)
            return .upgraded(0, Self.currentSchemaVersion)
        }
        throw IndexError.incompatibleSchema(version)
    }

    private func createSchemaIfNeeded(in database: OpaquePointer?) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """,
            in: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS media (
                stableMediaID TEXT PRIMARY KEY NOT NULL,
                normalizedPath TEXT NOT NULL UNIQUE,
                fileResourceIdentifier TEXT,
                modificationDate REAL,
                fileSize INTEGER,
                mediaType TEXT NOT NULL,
                pixelWidth INTEGER,
                pixelHeight INTEGER,
                orientation INTEGER,
                captureDate REAL,
                creationDate REAL,
                videoDuration REAL,
                pairedVideoStableID TEXT,
                pairedVideoPath TEXT,
                schemaVersion INTEGER NOT NULL
            )
            """,
            in: database
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS media_path_idx ON media(normalizedPath)",
            in: database
        )
    }

    private func selectItems(in database: OpaquePointer?) throws -> [ExternalMediaItem] {
        let sql = """
            SELECT stableMediaID, normalizedPath, fileResourceIdentifier,
                   modificationDate, fileSize, mediaType, pixelWidth, pixelHeight,
                   orientation, captureDate, creationDate, videoDuration,
                   pairedVideoStableID, pairedVideoPath, schemaVersion
            FROM media
            ORDER BY COALESCE(captureDate, creationDate, modificationDate, -62135769600.0) ASC,
                     normalizedPath ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.corrupt
        }
        defer { sqlite3_finalize(statement) }

        var items: [ExternalMediaItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(at: 0, in: statement),
                  let path = text(at: 1, in: statement),
                  let typeValue = text(at: 5, in: statement),
                  let mediaType = ExternalMediaType(rawValue: typeValue) else {
                continue
            }
            let pairedVideoPath = text(at: 13, in: statement)
            items.append(
                ExternalMediaItem(
                    stableMediaID: id,
                    url: URL(fileURLWithPath: path),
                    normalizedPath: path,
                    fileResourceIdentifier: text(at: 2, in: statement),
                    pairedVideoURL: pairedVideoPath.map(URL.init(fileURLWithPath:)),
                    pairedVideoStableID: text(at: 12, in: statement),
                    pairedVideoPath: pairedVideoPath,
                    mediaType: mediaType,
                    fileSize: int64(at: 4, in: statement),
                    creationDate: date(at: 10, in: statement),
                    modificationDate: date(at: 3, in: statement),
                    captureDate: date(at: 9, in: statement),
                    duration: double(at: 11, in: statement),
                    videoDuration: double(at: 11, in: statement),
                    pixelWidth: int(at: 6, in: statement),
                    pixelHeight: int(at: 7, in: statement),
                    orientation: int(at: 8, in: statement),
                    schemaVersion: int(at: 14, in: statement) ?? Self.currentSchemaVersion
                )
            )
        }
        return items
    }

    private func upsert(_ item: ExternalMediaItem, in database: OpaquePointer?) throws {
        let sql = """
            INSERT INTO media (
                stableMediaID, normalizedPath, fileResourceIdentifier,
                modificationDate, fileSize, mediaType, pixelWidth, pixelHeight,
                orientation, captureDate, creationDate, videoDuration,
                pairedVideoStableID, pairedVideoPath, schemaVersion
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(stableMediaID) DO UPDATE SET
                normalizedPath=excluded.normalizedPath,
                fileResourceIdentifier=excluded.fileResourceIdentifier,
                modificationDate=excluded.modificationDate,
                fileSize=excluded.fileSize,
                mediaType=excluded.mediaType,
                pixelWidth=excluded.pixelWidth,
                pixelHeight=excluded.pixelHeight,
                orientation=excluded.orientation,
                captureDate=excluded.captureDate,
                creationDate=excluded.creationDate,
                videoDuration=excluded.videoDuration,
                pairedVideoStableID=excluded.pairedVideoStableID,
                pairedVideoPath=excluded.pairedVideoPath,
                schemaVersion=excluded.schemaVersion
            """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement, in: database)
        defer { sqlite3_finalize(statement) }

        bind(item.stableMediaID, at: 1, in: statement)
        bind(item.normalizedPath, at: 2, in: statement)
        bind(item.fileResourceIdentifier, at: 3, in: statement)
        bind(item.modificationDate, at: 4, in: statement)
        bind(item.fileSize, at: 5, in: statement)
        bind(item.mediaType.rawValue, at: 6, in: statement)
        bind(item.pixelWidth, at: 7, in: statement)
        bind(item.pixelHeight, at: 8, in: statement)
        bind(item.orientation, at: 9, in: statement)
        bind(item.captureDate, at: 10, in: statement)
        bind(item.creationDate, at: 11, in: statement)
        bind(item.videoDuration, at: 12, in: statement)
        bind(item.pairedVideoStableID, at: 13, in: statement)
        bind(item.pairedVideoPath, at: 14, in: statement)
        bind(item.schemaVersion, at: 15, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw IndexError.sqlite(errorMessage(in: database))
        }
    }

    private func delete(stableMediaID: String, in database: OpaquePointer?) throws {
        var statement: OpaquePointer?
        try prepare("DELETE FROM media WHERE stableMediaID = ?", statement: &statement, in: database)
        defer { sqlite3_finalize(statement) }
        bind(stableMediaID, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw IndexError.sqlite(errorMessage(in: database))
        }
    }

    private func setMetadata(_ key: String, _ value: String, in database: OpaquePointer?) throws {
        var statement: OpaquePointer?
        try prepare(
            "INSERT INTO metadata(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            statement: &statement,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw IndexError.sqlite(errorMessage(in: database))
        }
    }

    private func metadata(_ key: String, in database: OpaquePointer?) throws -> String? {
        var statement: OpaquePointer?
        try prepare("SELECT value FROM metadata WHERE key = ?", statement: &statement, in: database)
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? text(at: 0, in: statement) : nil
    }

    private func tableExists(_ name: String, in database: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(name, at: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func transaction(in database: OpaquePointer?, body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION", in: database)
        do {
            try body()
            try execute("COMMIT", in: database)
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw IndexError.sqlite(errorMessage(in: database))
        }
    }

    private func prepare(
        _ sql: String,
        statement: inout OpaquePointer?,
        in database: OpaquePointer?
    ) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.sqlite(errorMessage(in: database))
        }
    }

    private func errorMessage(in database: OpaquePointer?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
    }
}

nonisolated private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
}

nonisolated private func bind(_ value: Date?, at index: Int32, in statement: OpaquePointer?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_double(statement, index, value.timeIntervalSinceReferenceDate)
}

nonisolated private func bind(_ value: TimeInterval?, at index: Int32, in statement: OpaquePointer?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_double(statement, index, value)
}

nonisolated private func bind(_ value: Int64?, at index: Int32, in statement: OpaquePointer?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_int64(statement, index, value)
}

nonisolated private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_int64(statement, index, Int64(value))
}

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

nonisolated private func date(at index: Int32, in statement: OpaquePointer?) -> Date? {
    double(at: index, in: statement).map(Date.init(timeIntervalSinceReferenceDate:))
}
