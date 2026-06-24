import Foundation

@MainActor
final class FFmpegProcessRunner {
    enum RunnerError: LocalizedError {
        case failedToLaunch(String)
        case failed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case let .failedToLaunch(message):
                return "无法启动 ffmpeg：\(message)"
            case let .failed(message):
                return message.isEmpty ? "ffmpeg 压缩失败。" : "ffmpeg 压缩失败：\(message)"
            case .cancelled:
                return "压缩已取消。"
            }
        }
    }

    private var process: Process?

    func run(
        executableURL: URL,
        arguments: [String],
        processingDuration: TimeInterval,
        progressHandler: @escaping @MainActor (VideoCompressionProgress) -> Void
    ) async throws {
        let process = Process()
        let progressPipe = Pipe()
        let errorPipe = Pipe()
        let parser = FFmpegProgressParser(processingDuration: processingDuration)
        let start = Date()
        let queue = DispatchQueue(label: "GladPhotos.FFmpegProcessRunner")
        var errorData = Data()
        var progressBuffer = Data()
        var didResume = false

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = progressPipe
        process.standardError = errorPipe

        progressPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            queue.async {
                progressBuffer.append(data)
                while let lineRange = progressBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = progressBuffer.subdata(in: progressBuffer.startIndex..<lineRange.lowerBound)
                    progressBuffer.removeSubrange(progressBuffer.startIndex...lineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8),
                          let update = parser.update(with: line) else { continue }
                    let elapsed = Date().timeIntervalSince(start)
                    Task { @MainActor in
                        progressHandler(VideoCompressionProgress(
                            fraction: update.fraction,
                            elapsed: elapsed,
                            speed: update.speed
                        ))
                    }
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            queue.async {
                errorData.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            throw RunnerError.failedToLaunch(error.localizedDescription)
        }

        self.process = process

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    queue.async {
                        guard !didResume else { return }
                        didResume = true
                        progressPipe.fileHandleForReading.readabilityHandler = nil
                        errorPipe.fileHandleForReading.readabilityHandler = nil

                        let message = String(data: errorData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if process.terminationStatus == 0 {
                            continuation.resume()
                        } else if process.terminationReason == .uncaughtSignal {
                            continuation.resume(throwing: RunnerError.cancelled)
                        } else {
                            continuation.resume(throwing: RunnerError.failed(message))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel()
            }
        }

        self.process = nil
    }

    func cancel() {
        process?.terminate()
        process = nil
    }
}

private final class FFmpegProgressParser: @unchecked Sendable {
    private let processingDuration: TimeInterval
    private var outTime: TimeInterval = 0
    private var speed: String?

    init(processingDuration: TimeInterval) {
        self.processingDuration = max(processingDuration, 0.001)
    }

    func update(with line: String) -> (fraction: Double, speed: String?)? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = String(parts[0])
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)

        switch key {
        case "out_time_us", "out_time_ms":
            if let microseconds = Double(value) {
                outTime = microseconds / 1_000_000
            }
        case "speed":
            speed = value.isEmpty || value == "N/A" ? nil : value
        case "progress":
            if value == "end" {
                outTime = processingDuration
            }
        default:
            break
        }

        return (min(max(outTime / processingDuration, 0), 1), speed)
    }
}
