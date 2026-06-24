import SwiftUI

struct VideoTrimPanel: View {
    let sourceURL: URL
    @ObservedObject var state: VideoTrimState
    let onCompressionCompleted: (URL) -> Void
    @StateObject private var exporter = VideoTrimExportService()
    @State private var compressionRange: VideoCompressionSheetItem?

    init(
        sourceURL: URL,
        state: VideoTrimState,
        onCompressionCompleted: @escaping (URL) -> Void = { _ in }
    ) {
        self.sourceURL = sourceURL
        self.state = state
        self.onCompressionCompleted = onCompressionCompleted
    }

    var body: some View {
        VStack(spacing: 12) {
            VideoTrimTimelineView(state: state)

            HStack(alignment: .bottom, spacing: 14) {
                PreciseTimeField(title: "开始", value: state.startTime) { state.setStartTime($0) }
                PreciseTimeField(title: "结束", value: state.endTime) { state.setEndTime($0) }

                VStack(alignment: .leading, spacing: 4) {
                    Text("片段时长")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(VideoTrimState.format(state.selectionDuration))
                        .font(.system(.body, design: .monospaced))
                }

                Spacer(minLength: 8)

                Button("重置") { state.reset() }
                    .disabled(!state.isReady || exporter.isExporting)
                    .pointingHandCursor()

                Button("导出片段") {
                    exporter.chooseDestinationAndExport(
                        sourceURL: sourceURL,
                        startTime: state.startTime,
                        endTime: state.endTime
                    )
                }
                .disabled(!state.isReady || exporter.isExporting)
                .buttonStyle(.borderedProminent)
                .pointingHandCursor()

                Button("导出压缩片段") {
                    compressionRange = VideoCompressionSheetItem(
                        range: .clip(start: state.startTime, end: state.endTime)
                    )
                }
                .disabled(!state.isReady || exporter.isExporting)
                .buttonStyle(.bordered)
                .pointingHandCursor()
            }

            if exporter.isExporting {
                HStack(spacing: 10) {
                    ProgressView(value: exporter.progress)
                    Text(exporter.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                    Button("取消") { exporter.cancel() }
                        .pointingHandCursor()
                }
            }

            if let path = exporter.resultMessage {
                Text("导出成功：\(path)")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let message = exporter.errorMessage ?? state.playbackError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.14))
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .sheet(item: $compressionRange) { item in
            VideoCompressionSheet(
                inputURL: sourceURL,
                range: item.range,
                totalDuration: state.duration,
                onCompleted: onCompressionCompleted
            )
        }
    }
}

private struct VideoCompressionSheetItem: Identifiable {
    let id = UUID()
    let range: VideoCompressionRange
}

private struct PreciseTimeField: View {
    let title: String
    let value: TimeInterval
    let onCommit: (TimeInterval) -> Void
    @State private var text: String

    init(title: String, value: TimeInterval, onCommit: @escaping (TimeInterval) -> Void) {
        self.title = title
        self.value = value
        self.onCommit = onCommit
        _text = State(initialValue: VideoTrimState.format(value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("HH:mm:ss.SSS", text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(width: 132)
                .onSubmit(commit)
                .onChange(of: value) { _, newValue in
                    text = VideoTrimState.format(newValue)
                }
        }
    }

    private func commit() {
        if let parsed = VideoTrimState.parse(text) {
            onCommit(parsed)
        }
        text = VideoTrimState.format(value)
    }
}
