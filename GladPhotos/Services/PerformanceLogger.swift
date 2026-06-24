import Foundation
import OSLog

nonisolated enum PerformanceLogger {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "GladPhotos",
        category: "Performance"
    )

    static func log(_ category: String, duration: Duration, details: String = "") {
        let milliseconds = duration.milliseconds
        logger.info("\(category, privacy: .public) \(milliseconds, format: .fixed(precision: 2), privacy: .public)ms \(details, privacy: .public)")
        if Thread.isMainThread, milliseconds > 16 {
            logger.warning("MAIN THREAD >16ms: \(category, privacy: .public) \(milliseconds, format: .fixed(precision: 2), privacy: .public)ms")
        }
    }
}

nonisolated private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
    }
}
