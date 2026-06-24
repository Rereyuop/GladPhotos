import SwiftUI

struct VideoSourceInfoPanel: View {
    let fileURL: URL

    @State private var state: LoadState = .loading

    var body: some View {
        SourceInfoPanelContainer {
            switch state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在分析原文件…")
                }
                .foregroundStyle(.secondary)
                .font(.body)
            case let .loaded(metadata):
                VideoMetadataContent(metadata: metadata)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 4) {
                    Text("无法读取原文件参数")
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.secondary)
                }
                .font(.body)
            }
        }
        .task(id: fileURL) {
            state = .loading
            do {
                let data = try await FFprobeRunner().run(for: fileURL)
                state = .loaded(try FFprobeJSONParser().parse(data))
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

struct ImageSourceInfoPanel: View {
    let metadata: ImageSourceMetadata

    var body: some View {
        SourceInfoPanelContainer {
            MetadataSection(title: "文件信息") {
                if let filename = metadata.filename, !filename.isEmpty {
                    MetadataRow(label: "文件名", value: filename)
                }
                if let codec = metadata.codec, !codec.isEmpty {
                    MetadataRow(label: "图片编码", value: codec)
                }
                if let width = metadata.width, let height = metadata.height,
                   width > 0, height > 0 {
                    MetadataRow(label: "尺寸", value: "\(width)×\(height)")
                }
                if let fileSize = metadata.fileSize, fileSize > 0 {
                    MetadataRow(label: "文件大小", value: ByteCountFormatter.string(
                        fromByteCount: fileSize,
                        countStyle: .file
                    ))
                }
                if let date = metadata.creationDate {
                    MetadataRow(
                        label: "拍摄日期",
                        value: date.formatted(.dateTime.locale(.gladPhotosChinese))
                    )
                }
            }
        }
    }
}

private struct VideoMetadataContent: View {
    let metadata: VideoSourceMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if metadata.duration != nil || metadata.containerBitrate != nil {
                MetadataSection(title: "文件信息") {
                    if let duration = metadata.duration {
                        MetadataRow(label: "时长", value: formatDuration(duration))
                    }
                    if let bitrate = metadata.containerBitrate {
                        MetadataRow(label: "容器码率", value: formatBitrate(bitrate))
                    }
                }
            }

            if let video = metadata.video {
                MetadataSection(title: "视频流") {
                    if let codec = video.codec {
                        MetadataRow(label: "视频编码", value: codec)
                    }
                    if let profile = video.profile {
                        MetadataRow(label: "Profile", value: profile)
                    }
                    if let width = video.width, let height = video.height {
                        MetadataRow(label: "分辨率", value: "\(width)×\(height)")
                    }
                    if let frameRate = video.frameRate {
                        MetadataRow(label: "帧率", value: formatFrameRate(frameRate))
                    }
                    if let pixelFormat = video.pixelFormat {
                        MetadataRow(label: "像素格式", value: pixelFormat)
                    }
                    if let colorSpace = video.colorSpace {
                        MetadataRow(label: "色彩空间", value: colorSpace)
                    }
                    if let colorRange = video.colorRange {
                        MetadataRow(label: "色彩范围", value: colorRange)
                    }
                    if let colorPrimaries = video.colorPrimaries {
                        MetadataRow(label: "色彩原色", value: colorPrimaries)
                    }
                    if let bitrate = video.bitrate {
                        MetadataRow(label: "视频码率", value: formatBitrate(bitrate))
                    }
                }
            }

            if !metadata.audioTracks.isEmpty {
                MetadataSection(title: "音频流") {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(metadata.audioTracks.enumerated()), id: \.element.id) { offset, track in
                            AudioTrackContent(number: offset + 1, track: track)
                        }
                    }
                }
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    private func formatFrameRate(_ rate: Double) -> String {
        let value = rate.rounded() == rate
            ? String(format: "%.0f", rate)
            : String(format: "%.3f", rate).replacingOccurrences(
                of: "\\.?0+$",
                with: "",
                options: .regularExpression
            )
        return "\(value) fps"
    }

    private func formatBitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            let value = String(format: "%.2f", bitsPerSecond / 1_000_000)
                .replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
            return "\(value) Mb/s"
        }
        return "\(Int((bitsPerSecond / 1_000).rounded())) kb/s"
    }
}

private struct AudioTrackContent: View {
    let number: Int
    let track: AudioStreamMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("音轨 #\(number)")
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 1)
            }
            .font(.subheadline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                if let codec = track.codec {
                    MetadataRow(label: "编码", value: codec)
                }
                if track.channels != nil || track.channelLayout != nil {
                    let channelCount = track.channels.map(String.init) ?? ""
                    let separator = track.channels != nil && track.channelLayout != nil ? " " : ""
                    let layout = track.channelLayout.map { "（\($0)）" } ?? ""
                    MetadataRow(label: "声道", value: "\(channelCount)\(separator)\(layout)")
                }
                if let sampleRate = track.sampleRate {
                    MetadataRow(label: "采样率", value: formatSampleRate(sampleRate))
                }
                if let bitrate = track.bitrate {
                    MetadataRow(label: "码率", value: formatBitrate(bitrate))
                }
                if let language = track.language {
                    MetadataRow(label: "语言", value: language)
                }
            }
        }
    }

    private func formatSampleRate(_ rate: Double) -> String {
        if rate >= 1_000 {
            let value = rate / 1_000
            return value.rounded() == value
                ? String(format: "%.0f kHz", value)
                : String(format: "%.1f kHz", value)
        }
        return String(format: "%.0f Hz", rate)
    }

    private func formatBitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.2f Mb/s", bitsPerSecond / 1_000_000)
        }
        return "\(Int((bitsPerSecond / 1_000).rounded())) kb/s"
    }
}

private struct MetadataSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                content
            }
        }
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .gridColumnAlignment(.trailing)
        }
        .font(.body)
    }
}

private struct SourceInfoPanelContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(width: 320)
        .frame(maxHeight: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.1))
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

private enum LoadState {
    case loading
    case loaded(VideoSourceMetadata)
    case failed(String)
}
