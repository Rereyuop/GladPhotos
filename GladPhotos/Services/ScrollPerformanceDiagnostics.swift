#if DEBUG
import CoreGraphics
import Foundation
import Photos

@MainActor
enum ScrollPerformanceDiagnostics {
    private static let enabledKey = "GladPhotos.scrollDiagnostics.enabled"

    private static var sectionOffsetPreferenceCallbacks = 0
    private static var sectionOffsetValuesTotal = 0
    private static var sectionOffsetValuesMax = 0
    private static var visibleDateCandidates = 0
    private static var visibleDatePublished = 0
    private static var cellAppearCount = 0
    private static var cellDisappearCount = 0
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
        sectionOffsetPreferenceCallbacks = 0
        sectionOffsetValuesTotal = 0
        sectionOffsetValuesMax = 0
        visibleDateCandidates = 0
        visibleDatePublished = 0
        cellAppearCount = 0
        cellDisappearCount = 0
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
        inflightRequests = [:]
        inflightRequestCountsByKey = [:]
        targetSizeDistribution = [:]
        scenarioStartedAt = Date()
        guard isEnabled else { return }
        print("DEBUG ScrollDiagnostics reset reason=\(reason)")
    }

    static func recordSectionOffsetPreference(valueCount: Int) {
        guard isEnabled else { return }
        sectionOffsetPreferenceCallbacks += 1
        sectionOffsetValuesTotal += valueCount
        sectionOffsetValuesMax = max(sectionOffsetValuesMax, valueCount)
    }

    static func recordVisibleDateCandidate() {
        guard isEnabled else { return }
        visibleDateCandidates += 1
    }

    static func recordVisibleDatePublished() {
        guard isEnabled else { return }
        visibleDatePublished += 1
    }

    static func recordCellAppear() {
        guard isEnabled else { return }
        cellAppearCount += 1
    }

    static func recordCellDisappear() {
        guard isEnabled else { return }
        cellDisappearCount += 1
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
        targetSize: CGSize
    ) {
        guard isEnabled else { return }
        thumbnailRequestStarted += 1

        if (inflightRequestCountsByKey[key] ?? 0) > 0 {
            duplicateEquivalentRequests += 1
        }

        inflightRequests[requestID] = key
        inflightRequestCountsByKey[key, default: 0] += 1
        peakInflightRequests = max(peakInflightRequests, inflightRequests.count)

        let sizeBucket = "\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))"
        targetSizeDistribution[sizeBucket, default: 0] += 1
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
        let averageOffsetValues = sectionOffsetPreferenceCallbacks == 0
            ? 0
            : Double(sectionOffsetValuesTotal) / Double(sectionOffsetPreferenceCallbacks)
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
            section_offset_preference_callbacks=\(sectionOffsetPreferenceCallbacks)
            section_offset_values_total=\(sectionOffsetValuesTotal)
            section_offset_values_avg=\(String(format: "%.2f", averageOffsetValues))
            section_offset_values_max=\(sectionOffsetValuesMax)
            visible_date_candidates=\(visibleDateCandidates)
            visible_date_published=\(visibleDatePublished)
            cell_appear_count=\(cellAppearCount)
            cell_disappear_count=\(cellDisappearCount)
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
