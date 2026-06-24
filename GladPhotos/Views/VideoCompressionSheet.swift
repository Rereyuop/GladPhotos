import Combine
import SwiftUI

struct VideoCompressionSheet: View {
    let inputURL: URL
    let range: VideoCompressionRange
    let totalDuration: TimeInterval
    let onCompleted: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = VideoCompressionViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("压缩视频")
                .font(.title2.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("处理范围")
                        .foregroundStyle(.secondary)
                    Text(rangeDescription)
                        .monospacedDigit()
                }
                GridRow {
                    Text("目标视频码率")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("4000", text: $viewModel.bitrateText)
                            .frame(width: 78)
                            .textFieldStyle(.roundedBorder)
                            .monospacedDigit()
                        Text("kbps")
                    }
                }
                GridRow {
                    Text("预计输出大小")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.estimatedSizeText)
                        if !viewModel.estimateIncludesAudio {
                            Text("预计值未完整计入音频")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                GridRow {
                    Text("音频")
                        .foregroundStyle(.secondary)
                    Text("保持原始")
                }
                GridRow {
                    Text("输出格式")
                        .foregroundStyle(.secondary)
                    Text("MP4")
                }
            }

            if viewModel.isCompressing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在压缩")
                        .font(.headline)
                    HStack(spacing: 10) {
                        ProgressView(value: viewModel.progress)
                        Text(viewModel.progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    HStack(spacing: 16) {
                        Text("已用时间 \(viewModel.elapsedText)")
                        Text("速度 \(viewModel.speedText)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let outputURL = viewModel.outputURL {
                Text("导出成功：\(outputURL.path)")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button(viewModel.isCompressing ? "取消" : "关闭") {
                    if viewModel.isCompressing {
                        viewModel.cancel()
                    } else {
                        dismiss()
                    }
                }
                .pointingHandCursor()

                Button("开始压缩") {
                    Task {
                        if let outputURL = await viewModel.compress(
                            inputURL: inputURL,
                            range: range,
                            totalDuration: totalDuration
                        ) {
                            onCompleted(outputURL)
                        }
                    }
                }
                .disabled(!viewModel.canStart)
                .buttonStyle(.borderedProminent)
                .pointingHandCursor()
            }
        }
        .padding(20)
        .frame(width: 460)
        .task(id: inputURL) {
            await viewModel.prepare(
                inputURL: inputURL,
                range: range,
                totalDuration: totalDuration
            )
        }
    }

    private var rangeDescription: String {
        switch range {
        case .fullVideo:
            return "完整视频"
        case let .clip(start, end):
            return "\(VideoTrimState.format(start))-\(VideoTrimState.format(end))（\(Int((end - start).rounded())) 秒）"
        }
    }
}

@MainActor
final class VideoCompressionViewModel: ObservableObject {
    @Published var bitrateText = "4000" {
        didSet { updateEstimate() }
    }
    @Published private(set) var estimatedSizeText = "约 -- MB"
    @Published private(set) var estimateIncludesAudio = true
    @Published private(set) var isCompressing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var elapsedText = "00:00"
    @Published private(set) var speedText = "--"
    @Published private(set) var errorMessage: String?
    @Published private(set) var outputURL: URL?

    private let probeService = VideoProbeService()
    private let compressionService = VideoCompressionService()
    private var metadata: VideoSourceMetadata?
    private var processingDuration: TimeInterval = 0

    var canStart: Bool {
        !isCompressing && validBitrate != nil && processingDuration > 0
    }

    func prepare(inputURL: URL, range: VideoCompressionRange, totalDuration: TimeInterval) async {
        processingDuration = range.processingDuration(totalDuration: totalDuration) ?? 0
        errorMessage = nil
        outputURL = nil
        do {
            let metadata = try await probeService.metadata(for: inputURL)
            self.metadata = metadata
            bitrateText = String(probeService.defaultTargetVideoBitrateKbps(for: metadata))
            updateEstimate()
        } catch {
            metadata = nil
            bitrateText = "4000"
            updateEstimate()
        }
    }

    func compress(inputURL: URL, range: VideoCompressionRange, totalDuration: TimeInterval) async -> URL? {
        guard let bitrate = validBitrate else {
            errorMessage = "目标视频码率必须是合理的正整数。"
            return nil
        }

        let outputURL = VideoCompressionService.uniqueOutputURL(
            for: inputURL,
            range: range,
            targetVideoBitrateKbps: bitrate
        )
        let request = VideoCompressionRequest(
            inputURL: inputURL,
            outputURL: outputURL,
            range: range,
            targetVideoBitrateKbps: bitrate
        )

        isCompressing = true
        progress = 0
        elapsedText = "00:00"
        speedText = "--"
        errorMessage = nil
        self.outputURL = nil

        do {
            try await compressionService.compress(
                request: request,
                totalDuration: totalDuration
            ) { [weak self] progress in
                self?.progress = progress.fraction
                self?.elapsedText = Self.formatElapsed(progress.elapsed)
                self?.speedText = progress.speed ?? "--"
            }
            progress = 1
            self.outputURL = outputURL
            isCompressing = false
            return outputURL
        } catch {
            isCompressing = false
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func cancel() {
        compressionService.cancel()
        isCompressing = false
        errorMessage = "压缩已取消。"
    }

    private var validBitrate: Int? {
        guard let value = Int(bitrateText.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0,
              value <= 500_000
        else { return nil }
        return value
    }

    private func updateEstimate() {
        guard let bitrate = validBitrate, processingDuration > 0 else {
            estimatedSizeText = "约 -- MB"
            estimateIncludesAudio = true
            return
        }
        let estimate = probeService.estimatedOutputSize(
            targetVideoBitrateKbps: bitrate,
            duration: processingDuration,
            metadata: metadata ?? VideoSourceMetadata(
                duration: nil,
                containerBitrate: nil,
                video: nil,
                audioTracks: []
            )
        )
        estimateIncludesAudio = estimate.includesAudio
        estimatedSizeText = "约 \(Self.formatMegabytes(estimate.bytes)) MB"
    }

    private static func formatMegabytes(_ bytes: Double) -> String {
        let megabytes = bytes / 1_000_000
        return megabytes >= 100 ? String(format: "%.0f", megabytes) : String(format: "%.1f", megabytes)
    }

    private static func formatElapsed(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
