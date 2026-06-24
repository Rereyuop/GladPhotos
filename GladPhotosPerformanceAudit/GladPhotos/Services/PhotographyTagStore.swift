import Foundation

actor PhotographyTagStore {
    private var recordsByPath: [String: PhotographyAnalysisRecord] = [:]
    private var didLoad = false
    private var scheduledPersistTask: Task<Void, Never>?
    private var dirtyByPath: [String: PhotographyAnalysisRecord] = [:]
    private let fileURL: URL
    private let updatesURL: URL

    init(folderID: UUID, fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folderDirectory = base
            .appendingPathComponent("GladPhotos", isDirectory: true)
            .appendingPathComponent("ExternalRecognition", isDirectory: true)
            .appendingPathComponent(folderID.uuidString, isDirectory: true)
        fileURL = folderDirectory
            .appendingPathComponent("PhotographyTags.json")
        updatesURL = folderDirectory
            .appendingPathComponent("PhotographyTagUpdates.jsonl")
    }

    nonisolated static func removePersistedRecords(
        for folderID: UUID,
        fileManager: FileManager = .default
    ) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base
            .appendingPathComponent("GladPhotos", isDirectory: true)
            .appendingPathComponent("ExternalRecognition", isDirectory: true)
            .appendingPathComponent(folderID.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: directory)
    }

    func records(for items: [ExternalMediaItem]) -> [String: PhotographyAnalysisRecord] {
        loadIfNeeded()
        var result: [String: PhotographyAnalysisRecord] = [:]
        for item in items where item.mediaType != .video {
            let path = item.url.standardizedFileURL.path
            let existing = recordsByPath[path]
            let record: PhotographyAnalysisRecord
            if let existing, existing.matches(item) {
                record = existing
            } else {
                record = PhotographyAnalysisRecord(
                    filePath: path,
                    fileSize: item.fileSize,
                    modificationDate: item.modificationDate,
                    resourceIdentifier: Self.resourceIdentifier(for: item.url),
                    predictedTag: .unknown,
                    confidence: 0,
                    manualTag: existing?.manualTag,
                    analysisMethod: .model,
                    modelVersion: nil,
                    analyzedAt: nil
                )
                recordsByPath[path] = record
            }
            result[path] = record
        }
        return result
    }

    func save(
        _ classification: PhotographyClassification,
        for item: ExternalMediaItem
    ) -> PhotographyAnalysisRecord {
        loadIfNeeded()
        let path = item.url.standardizedFileURL.path
        let old = recordsByPath[path]
        let record = PhotographyAnalysisRecord(
            filePath: path,
            fileSize: item.fileSize,
            modificationDate: item.modificationDate,
            resourceIdentifier: Self.resourceIdentifier(for: item.url),
            predictedTag: classification.tag,
            confidence: classification.confidence,
            manualTag: old?.manualTag,
            analysisMethod: classification.method,
            modelVersion: classification.modelVersion,
            analyzedAt: Date()
        )
        recordsByPath[path] = record
        dirtyByPath[path] = record
        schedulePersist()
        return record
    }

    func setManualTag(
        _ tag: PhotographyTag?,
        for items: [ExternalMediaItem]
    ) -> [String: PhotographyAnalysisRecord] {
        var current = records(for: items)
        for item in items where item.mediaType != .video {
            let path = item.url.standardizedFileURL.path
            guard var record = current[path] else { continue }
            record.manualTag = tag
            recordsByPath[path] = record
            dirtyByPath[path] = record
            current[path] = record
        }
        schedulePersist()
        return current
    }

    func flush() {
        scheduledPersistTask?.cancel()
        scheduledPersistTask = nil
        persistDirtyRecords()
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let data = try? Data(contentsOf: fileURL),
           let records = try? JSONDecoder().decode([PhotographyAnalysisRecord].self, from: data) {
            recordsByPath = Dictionary(uniqueKeysWithValues: records.map { ($0.filePath, $0) })
        }
        guard let updates = try? String(contentsOf: updatesURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        for line in updates.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(PhotographyAnalysisRecord.self, from: data)
            else { continue }
            recordsByPath[record.filePath] = record
        }
    }

    private func persistDirtyRecords() {
        guard !dirtyByPath.isEmpty else { return }
        let writeStart = ContinuousClock.now
        let records = Array(dirtyByPath.values)
        let encoder = JSONEncoder()
        let payload = records.compactMap { record -> Data? in
            guard var data = try? encoder.encode(record) else { return nil }
            data.append(0x0A)
            return data
        }.reduce(into: Data()) { $0.append($1) }
        guard !payload.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: updatesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: updatesURL.path) {
                FileManager.default.createFile(atPath: updatesURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: updatesURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            try handle.close()
            for record in records where dirtyByPath[record.filePath] == record {
                dirtyByPath[record.filePath] = nil
            }
        } catch {
            // A failed cache write must not interrupt browsing or discard in-memory labels.
        }
        PerformanceLogger.log(
            "json-write",
            duration: writeStart.duration(to: .now),
            details: "incrementalRecords=\(records.count) bytes=\(payload.count)"
        )
    }

    private func schedulePersist() {
        guard scheduledPersistTask == nil else { return }
        scheduledPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.persistScheduledRecords()
        }
    }

    private func persistScheduledRecords() {
        scheduledPersistTask = nil
        persistDirtyRecords()
    }

    nonisolated private static func resourceIdentifier(for url: URL) -> String {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        let values = try? url.resourceValues(forKeys: keys)
        return [
            values?.volumeIdentifier.map(String.init(describing:)),
            values?.fileResourceIdentifier.map(String.init(describing:)),
            url.standardizedFileURL.path
        ].compactMap { $0 }.joined(separator: "|")
    }
}
