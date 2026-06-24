import SwiftUI

private struct PhotoGridThumbnailWidthKey: FocusedValueKey {
    typealias Value = Binding<CGFloat>
}

extension FocusedValues {
    var photoGridThumbnailWidth: Binding<CGFloat>? {
        get { self[PhotoGridThumbnailWidthKey.self] }
        set { self[PhotoGridThumbnailWidthKey.self] = newValue }
    }
}

private struct PhotoGridCommands: Commands {
    @FocusedBinding(\.photoGridThumbnailWidth) private var thumbnailWidth

    var body: some Commands {
        CommandMenu("照片显示") {
            Button("放大照片") {
                if let thumbnailWidth {
                    self.thumbnailWidth = min(thumbnailWidth + 16, 256)
                }
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled((thumbnailWidth ?? 256) >= 256)

            Button("缩小照片") {
                if let thumbnailWidth {
                    self.thumbnailWidth = max(thumbnailWidth - 16, 64)
                }
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled((thumbnailWidth ?? 64) <= 64)
        }

        #if DEBUG
        CommandMenu("滚动诊断") {
            Button("启用滚动诊断") {
                Task { @MainActor in
                    ScrollPerformanceDiagnostics.setEnabled(true)
                    ScrollPerformanceDiagnostics.reset(reason: "enabled")
                }
            }

            Button("关闭滚动诊断") {
                Task { @MainActor in
                    ScrollPerformanceDiagnostics.setEnabled(false)
                }
            }

            Button("重置滚动诊断场景") {
                Task { @MainActor in
                    ScrollPerformanceDiagnostics.reset(reason: "manual")
                }
            }

            Button("结束场景并输出摘要") {
                Task { @MainActor in
                    ScrollPerformanceDiagnostics.printSummaryAndReset(
                        reason: "manual-scenario-end"
                    )
                }
            }
        }
        #endif
    }
}

extension Locale {
    static let gladPhotosChinese = Locale(identifier: "zh-Hans-CN")
}

@main
struct GladPhotosApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, .gladPhotosChinese)
        }
        .commands {
            PhotoGridCommands()
        }
    }
}
