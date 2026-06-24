import Foundation

struct FFprobeRunner: Sendable {
    enum RunnerError: LocalizedError {
        case executableNotFound
        case failedToLaunch(String)
        case probeFailed(String)
        case noOutput

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return "未找到 ffprobe。请安装 FFmpeg，或将 ffprobe 放入应用包。"
            case let .failedToLaunch(message):
                return "无法启动 ffprobe：\(message)"
            case let .probeFailed(message):
                return message.isEmpty ? "ffprobe 读取失败。" : "ffprobe 读取失败：\(message)"
            case .noOutput:
                return "ffprobe 没有返回媒体信息。"
            }
        }
    }

    func run(for fileURL: URL) async throws -> Data {
        let executableURL = try Self.ffprobeURL()

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = [
                "-v", "error",
                "-show_format",
                "-show_streams",
                "-of", "json",
                fileURL.path
            ]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw RunnerError.failedToLaunch(error.localizedDescription)
            }

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw RunnerError.probeFailed(message)
            }
            guard !output.isEmpty else {
                throw RunnerError.noOutput
            }
            return output
        }.value
    }

    nonisolated static func ffprobeURL() throws -> URL {
        if let bundledURL = Bundle.main.url(forAuxiliaryExecutable: "ffprobe") {
            return bundledURL
        }

        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw RunnerError.executableNotFound
    }
}

