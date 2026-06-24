#if DEBUG
import CoreGraphics
import Foundation
import Photos

@MainActor
enum ScrollPerformanceDiagnostics {
    private static let enabledKey = "GladPhotos.scrollDiagnostics.enabled"

    private static var visibleDateCandidates = 0
    private static var visibleDatePublished = 0
    private static var nativeCollectionItemsCreated = 0
    private static var nativeCollectionItemsReused = 0
    private static var nativeCollectionMaxVisibleItems = 0
    private static var nativeCollectionReloadDataCount = 0
    private static var thumbnailRequestStarted = 0
    private static var thumbnailRequestCancelled = 0
    private static var thumbnailDegradedResults = 0
    private static var thumbnailFinalResults = 0
    private static var thumbnailCancelledResults = 0
    private static var thumbnailErrorResults = 0
    private static var thumbnailDegradedReceived = 0
    private static var thumbnailDegradedCommittedToUI = 0
    private static var thumbnailDegradedSuppressedByFinal = 0
    private static var thumbnailFinalCommittedToUI = 0
    private static var duplicateEquivalentRequests = 0
    private static var peakInflightRequests = 0
    private static var preheatUpdateCount = 0
    private static var preheatAssetsAdded = 0
    private static var preheatAssetsRemoved = 0
    private static var preheatActiveAssets = 0
    private static var preheatActiveAssetsPeak = 0
    private static var preheatStartCalls = 0
    private static var preheatStopCalls = 0
    private static var preheatWindowResets = 0
    private static var preheatVisibleEventCount = 0
    private static var preheatIndexRebuildCount = 0
    private static var preheatComputationCount = 0
    private static var preheatWindowUnchangedSkips = 0
    private static var thumbnailRequestPreheatedCandidate = 0
    private static var preheatedCandidateIdentifiers = Set<String>()
    private static var inflightRequests: [PHImageRequestID: String] = [:]
    private static var inflightRequestCountsByKey: [String: Int] = [:]
    private static var targetSizeDistribution: [String: Int] = [:]
    private static var scenarioStartedAt: Date?

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        print("DEBUG ScrollDiagnostics \(enabled ? "enabled" : "disabled")")
    }

    static func reset(reason: String = "manual") {
        visibleDateCandidates = 0
        visibleDatePublished = 0
        nativeCollectionItemsCreated = 0
        nativeCollectionItemsReused = 0
        nativeCollectionMaxVisibleItems = 0
        nativeCollectionReloadDataCount = 0
        thumbnailRequestStarted = 0
        thumbnailRequestCancelled = 0
        thumbnailDegradedResults = 0
        thumbnailFinalResults = 0
        thumbnailCancelledResults = 0
        thumbnailErrorResults = 0
        thumbnailDegradedReceived = 0
        thumbnailDegradedCommittedToUI = 0
        thumbnailDegradedSuppressedByFinal = 0
        thumbnailFinalCommittedToUI = 0
        duplicateEquivalentRequests = 0
        peakInflightRequests = 0
        preheatUpdateCount = 0
        preheatAssetsAdded = 0
        preheatAssetsRemoved = 0
        preheatActiveAssets = 0
        preheatActiveAssetsPeak = 0
        preheatStartCalls = 0
        preheatStopCalls = 0
        preheatWindowResets = 0
        preheatVisibleEventCount = 0
        preheatIndexRebuildCount = 0
        preheatComputationCount = 0
        preheatWindowUnchangedSkips = 0
        thumbnailRequestPreheatedCandidate = 0
        preheatedCandidateIdentifiers = []
        inflightRequests = [:]
        inflightRequestCountsByKey = [:]
        targetSizeDistribution = [:]
        scenarioStartedAt = Date()
        guard isEnabled else { return }
        print("DEBUG ScrollDiagnostics reset reason=\(reason)")
    }

    static func recordVisibleDateCandidate() {
        guard isEnabled else { return }
        visibleDateCandidates += 1
    }

    static func recordVisibleDatePublished() {
        guard isEnabled else { return }
        visibleDatePublished += 1
    }

    static func recordNativeCollectionStats(
        createdItems: Int,
        reusedItems: Int,
        maxVisibleItems: Int,
        reloadDataCount: Int
    ) {
        guard isEnabled else { return }
        nativeCollectionItemsCreated = max(nativeCollectionItemsCreated, createdItems)
        nativeCollectionItemsReused = max(nativeCollectionItemsReused, reusedItems)
        nativeCollectionMaxVisibleItems = max(nativeCollectionMaxVisibleItems, maxVisibleItems)
        nativeCollectionReloadDataCount = max(nativeCollectionReloadDataCount, reloadDataCount)
    }

    static func makeThumbnailRequestKey(
        assetIdentifier: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) -> String {
        let width = Int(targetSize.width.rounded())
        let height = Int(targetSize.height.rounded())
        return "\(assetIdentifier)|\(width)x\(height)|mode=\(contentMode.rawValue)"
    }

    static func recordThumbnailRequestStarted(
        requestID: PHImageRequestID,
        key: String,
        targetSize: CGSize,
        isPreheatedCandidate: Bool = false
    ) {
        guard isEnabled else { return }
        thumbnailRequestStarted += 1
        if isPreheatedCandidate {
            thumbnailRequestPreheatedCandidate += 1
        }

        if (inflightRequestCountsByKey[key] ?? 0) > 0 {
            duplicateEquivalentRequests += 1
        }

        inflightRequests[requestID] = key
        inflightRequestCountsByKey[key, default: 0] += 1
        peakInflightRequests = max(peakInflightRequests, inflightRequests.count)

        let sizeBucket = "\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))"
        targetSizeDistribution[sizeBucket, default: 0] += 1
    }

    static func isThumbnailPreheatedCandidate(_ identifier: String) -> Bool {
        guard isEnabled else { return false }
        return preheatedCandidateIdentifiers.contains(identifier)
    }

    static func recordPreheatUpdate(
        addedAssets: Int,
        removedAssets: Int,
        activeAssets: Int,
        startCalls: Int,
        stopCalls: Int
    ) {
        guard isEnabled else { return }
        preheatUpdateCount += 1
        preheatAssetsAdded += addedAssets
        preheatAssetsRemoved += removedAssets
        preheatActiveAssets = activeAssets
        preheatActiveAssetsPeak = max(preheatActiveAssetsPeak, activeAssets)
        preheatStartCalls += startCalls
        preheatStopCalls += stopCalls
    }

    static func updatePreheatedCandidateIdentifiers(_ identifiers: Set<String>) {
        guard isEnabled else { return }
        preheatedCandidateIdentifiers = identifiers
    }

    static func recordPreheatWindowReset() {
        guard isEnabled else { return }
        preheatWindowResets += 1
    }

    static func recordPreheatVisibleEvent() {
        guard isEnabled else { return }
        preheatVisibleEventCount += 1
    }

    static func recordPreheatIndexRebuild() {
        guard isEnabled else { return }
        preheatIndexRebuildCount += 1
    }

    static func recordPreheatComputation() {
        guard isEnabled else { return }
        preheatComputationCount += 1
    }

    static func recordPreheatWindowUnchangedSkip() {
        guard isEnabled else { return }
        preheatWindowUnchangedSkips += 1
    }

    static func recordThumbnailRequestCancelled(_ requestID: PHImageRequestID?) {
        guard isEnabled, let requestID else { return }
        guard let key = inflightRequests.removeValue(forKey: requestID) else {
            return
        }

        thumbnailRequestCancelled += 1
        decrementInflightCount(for: key)
    }

    static func recordThumbnailCallback(
        requestID: PHImageRequestID,
        isDegraded: Bool,
        isCancelled: Bool,
        hasError: Bool
    ) {
        guard isEnabled else { return }

        if isCancelled {
            thumbnailCancelledResults += 1
            completeRequestIfNeeded(requestID)
            return
        }

        if hasError {
            thumbnailErrorResults += 1
            completeRequestIfNeeded(requestID)
            return
        }

        if isDegraded {
            thumbnailDegradedResults += 1
        } else {
            thumbnailFinalResults += 1
            completeRequestIfNeeded(requestID)
        }
    }

    static func recordThumbnailDegradedReceived() {
        guard isEnabled else { return }
        thumbnailDegradedReceived += 1
    }

    static func recordThumbnailDegradedCommittedToUI() {
        guard isEnabled else { return }
        thumbnailDegradedCommittedToUI += 1
    }

    static func recordThumbnailDegradedSuppressedByFinal() {
        guard isEnabled else { return }
        thumbnailDegradedSuppressedByFinal += 1
    }

    static func recordThumbnailFinalCommittedToUI() {
        guard isEnabled else { return }
        thumbnailFinalCommittedToUI += 1
    }

    static func printSummaryAndReset(reason: String = "manual") {
        printSummary(reason: reason)
        reset(reason: "after-summary")
    }

    private static func printSummary(reason: String) {
        guard isEnabled else {
            print("DEBUG ScrollDiagnostics summary skipped; diagnostics disabled")
            return
        }

        let duration = scenarioStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let targetSizes = targetSizeDistribution
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ", ")

        print(
            """
            DEBUG ScrollDiagnostics summary reason=\(reason)
            duration_seconds=\(String(format: "%.2f", duration))
            visible_date_candidates=\(visibleDateCandidates)
            visible_date_published=\(visibleDatePublished)
            native_collection_items_created=\(nativeCollectionItemsCreated)
            native_collection_items_reused=\(nativeCollectionItemsReused)
            native_collection_max_visible_items=\(nativeCollectionMaxVisibleItems)
            native_collection_reload_data_count=\(nativeCollectionReloadDataCount)
            thumbnail_request_started=\(thumbnailRequestStarted)
            thumbnail_request_cancelled=\(thumbnailRequestCancelled)
            thumbnail_degraded_results=\(thumbnailDegradedResults)
            thumbnail_final_results=\(thumbnailFinalResults)
            thumbnail_cancelled_results=\(thumbnailCancelledResults)
            thumbnail_error_results=\(thumbnailErrorResults)
            degraded_received=\(thumbnailDegradedReceived)
            degraded_committed_to_ui=\(thumbnailDegradedCommittedToUI)
            degraded_suppressed_by_final=\(thumbnailDegradedSuppressedByFinal)
            final_committed_to_ui=\(thumbnailFinalCommittedToUI)
            duplicate_equivalent_requests=\(duplicateEquivalentRequests)
            peak_inflight_requests=\(peakInflightRequests)
            inflight_requests_at_summary=\(inflightRequests.count)
            preheat_update_count=\(preheatUpdateCount)
            preheat_assets_added=\(preheatAssetsAdded)
            preheat_assets_removed=\(preheatAssetsRemoved)
            preheat_active_assets=\(preheatActiveAssets)
            preheat_active_assets_peak=\(preheatActiveAssetsPeak)
            preheat_start_calls=\(preheatStartCalls)
            preheat_stop_calls=\(preheatStopCalls)
            preheat_window_resets=\(preheatWindowResets)
            preheat_visible_event_count=\(preheatVisibleEventCount)
            preheat_index_rebuild_count=\(preheatIndexRebuildCount)
            preheat_computation_count=\(preheatComputationCount)
            preheat_window_unchanged_skips=\(preheatWindowUnchangedSkips)
            thumbnail_request_preheated_candidate=\(thumbnailRequestPreheatedCandidate)
            target_size_distribution=\(targetSizes.isEmpty ? "none" : targetSizes)
            """
        )
    }

    private static func completeRequestIfNeeded(_ requestID: PHImageRequestID) {
        guard let key = inflightRequests.removeValue(forKey: requestID) else {
            return
        }
        decrementInflightCount(for: key)
    }

    private static func decrementInflightCount(for key: String) {
        guard let count = inflightRequestCountsByKey[key] else {
            return
        }

        if count <= 1 {
            inflightRequestCountsByKey[key] = nil
        } else {
            inflightRequestCountsByKey[key] = count - 1
        }
    }
}
#endif
