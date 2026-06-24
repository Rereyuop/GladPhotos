import Foundation

@MainActor
final class PhotographyClassificationService {
    struct Progress: Equatable {
        let completed: Int
        let total: Int
    }

    private let store: PhotographyTagStore
    private let classifier: any PhotographyClassifier
    private let pauseGate = ClassificationPauseGate()
    private var task: Task<Void, Never>?

    init(
        store: PhotographyTagStore,
        classifier: any PhotographyClassifier = DefaultPhotographyClassifier()
    ) {
        self.store = store
        self.classifier = classifier
    }

    func analyze(
        items: [ExternalMediaItem],
        records: [String: PhotographyAnalysisRecord],
        onProgress: @escaping @MainActor (Progress, [PhotographyAnalysisRecord]) -> Void,
        onCompletion: @escaping @MainActor () -> Void
    ) {
        cancel()
        let candidates = items.filter { item in
            guard item.mediaType != .video else { return false }
            let record = records[item.url.standardizedFileURL.path]
            guard record?.manualTag == nil else { return false }
            return record == nil || record?.analyzedAt == nil || record?.predictedTag == .unknown
                || record?.matches(item) == false
        }
        task = Task(priority: .utility) { [store, classifier, pauseGate] in
            let analysisStart = ContinuousClock.now
            let total = candidates.count
            onProgress(Progress(completed: 0, total: total), [])
            var completed = 0
            var pendingRecords: [PhotographyAnalysisRecord] = []
            var lastPublication = ContinuousClock.now
            await withTaskGroup(
                of: (ExternalMediaItem, PhotographyClassification).self
            ) { group in
                var iterator = candidates.makeIterator()
                for _ in 0..<2 {
                    guard let item = iterator.next() else { break }
                    group.addTask {
                        await pauseGate.waitIfPaused()
                        let result = await Task.detached(priority: .background) {
                            await classifier.classify(item)
                        }.value
                        return (item, result)
                    }
                }

                while let (item, classification) = await group.next() {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    let record = await store.save(classification, for: item)
                    completed += 1
                    pendingRecords.append(record)

                    // A metadata-only classification can finish hundreds of files
                    // per second. Publishing every result made the grid repeatedly
                    // diff and regroup the whole folder. Keep progress responsive,
                    // but deliver records to SwiftUI in small batches.
                    let now = ContinuousClock.now
                    if pendingRecords.count >= 16
                        || lastPublication.duration(to: now) >= .milliseconds(100) {
                        onProgress(
                            Progress(completed: completed, total: total),
                            pendingRecords
                        )
                        pendingRecords.removeAll(keepingCapacity: true)
                        lastPublication = now
                    }
                    if let nextItem = iterator.next() {
                        group.addTask {
                            await pauseGate.waitIfPaused()
                            let result = await Task.detached(priority: .background) {
                                await classifier.classify(nextItem)
                            }.value
                            return (nextItem, result)
                        }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            if !pendingRecords.isEmpty {
                onProgress(
                    Progress(completed: completed, total: total),
                    pendingRecords
                )
            }
            await store.flush()
            PerformanceLogger.log(
                "recognition",
                duration: analysisStart.duration(to: .now),
                details: "items=\(completed)"
            )
            onCompletion()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        Task { await store.flush() }
    }

    func setPaused(_ paused: Bool) {
        Task { await pauseGate.setPaused(paused) }
    }
}

private actor ClassificationPauseGate {
    private var paused = false

    func setPaused(_ value: Bool) {
        paused = value
    }

    func waitIfPaused() async {
        while paused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
