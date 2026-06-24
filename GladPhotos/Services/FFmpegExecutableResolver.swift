import Foundation

struct FFmpegExecutableResolver: Sendable {
    enum ResolverError: LocalizedError {
        case executableNotFound

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return "未找到 ffmpeg。请安装 FFmpeg，或将 ffmpeg 放入应用包。"
            }
        }
    }

    func resolve() throws -> URL {
        if let bundledURL = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") {
            return bundledURL
        }

        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw ResolverError.executableNotFound
    }
}
