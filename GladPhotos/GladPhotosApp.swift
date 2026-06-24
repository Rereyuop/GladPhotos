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
