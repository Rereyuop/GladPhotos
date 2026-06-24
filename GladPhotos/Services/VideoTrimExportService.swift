import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class VideoTrimExportService: ObservableObject {
    enum ExportError: LocalizedError {
        case unsupportedContainer(String)
        case cannotCreateSession
        case invalidRange
        case destinationExists

        var errorDescription: String? {
            switch self {
            case .unsupportedContainer(let extensionName):
                return "当前格式（\(extensionName.uppercased())）不支持 AVFoundation 原生导出，暂未接入 FFmpeg。"
            case .cannotCreateSession:
                return "无法为此视频创建原生导出会话。"
            case .invalidRange:
                return "裁剪时间范围无效。"
            case .destinationExists:
                return "目标文件已存在，请选择一个新的文件名。"
            }
        }
    }

    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var resultMessage: String?
    @Published private(set) var errorMessage: String?

    private var exportSession: AVAssetExportSession?
    private var exportTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    func chooseDestinationAndExport(sourceURL: URL, startTime: TimeInterval, endTime: TimeInterval) {
        do {
            let fileType = try nativeFileType(for: sourceURL)
            let panel = NSSavePanel()
            panel.title = "导出裁剪片段"
            panel.nameFieldStringValue = "\(sourceURL.deletingPathExtension().lastPathComponent)-trimmed.\(sourceURL.pathExtension)"
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.allowedContentTypes = [UTType(filenameExtension: sourceURL.pathExtension) ?? .movie]

            guard panel.runModal() == .OK, let outputURL = panel.url else { return }
            startExport(
                sourceURL: sourceURL,
                outputURL: outputURL,
                fileType: fileType,
                startTime: startTime,
                endTime: endTime
            )
        } catch {
            errorMessage = error.localizedDescription
            resultMessage = nil
        }
    }

    func cancel() {
        exportSession?.cancelExport()
        exportTask?.cancel()
        progressTask?.cancel()
        exportSession = nil
        exportTask = nil
        progressTask = nil
        isExporting = false
        errorMessage = "导出已取消。"
    }

    private func startExport(
        sourceURL: URL,
        outputURL: URL,
        fileType: AVFileType,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        guard endTime > startTime else {
            errorMessage = ExportError.invalidRange.localizedDescription
            return
        }
        guard outputURL.standardizedFileURL != sourceURL.standardizedFileURL else {
            errorMessage = "不能覆盖原视频，请选择新的文件名。"
            return
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            errorMessage = ExportError.destinationExists.localizedDescription
            return
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            errorMessage = ExportError.cannotCreateSession.localizedDescription
            return
        }
        guard session.supportedFileTypes.contains(fileType) else {
            errorMessage = ExportError.unsupportedContainer(sourceURL.pathExtension).localizedDescription
            return
        }

        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let duration = CMTime(seconds: endTime - startTime, preferredTimescale: 600)
        session.timeRange = CMTimeRange(start: start, duration: duration)
        session.shouldOptimizeForNetworkUse = true

        exportSession = session
        isExporting = true
        progress = 0
        resultMessage = nil
        errorMessage = nil

        progressTask = Task { [weak self, weak session] in
            while let self, let session, !Task.isCancelled, self.isExporting {
                self.progress = Double(session.progress)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        exportTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                try await session.export(to: outputURL, as: fileType)
                guard !Task.isCancelled else { return }
                self.progress = 1
                self.resultMessage = outputURL.path
            } catch {
                if !Task.isCancelled {
                    try? FileManager.default.removeItem(at: outputURL)
                    self.errorMessage = error.localizedDescription
                }
            }
            self.finishExport()
        }
    }

    private func finishExport() {
        progressTask?.cancel()
        progressTask = nil
        exportTask = nil
        exportSession = nil
        isExporting = false
    }

    private func nativeFileType(for url: URL) throws -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov": return .mov
        case "mp4": return .mp4
        case "m4v": return .m4v
        default: throw ExportError.unsupportedContainer(url.pathExtension)
        }
    }
}
