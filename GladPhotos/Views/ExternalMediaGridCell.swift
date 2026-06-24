import AppKit
import SwiftUI

struct ExternalMediaGridCell: View, Equatable {
    let item: ExternalMediaItem
    let thumbnailService: ExternalThumbnailService
    let displayMode: PhotoGridDisplayMode
    let thumbnailWidth: CGFloat
    let showsMediaInfo: Bool
    let showsRecognitionInfo: Bool
    let record: PhotographyAnalysisRecord?
    let isSelecting: Bool
    let isSelected: Bool
    let allowsFinalThumbnail: Bool
    let finalLoadID: UUID
    let open: () -> Void
    let toggleSelection: () -> Void
    let setManualTag: (PhotographyTag?) -> Void

    @State private var isHovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.displayMode.title == rhs.displayMode.title
            && lhs.thumbnailWidth == rhs.thumbnailWidth
            && lhs.showsMediaInfo == rhs.showsMediaInfo
            && lhs.showsRecognitionInfo == rhs.showsRecognitionInfo
            && lhs.record == rhs.record
            && lhs.isSelecting == rhs.isSelecting
            && lhs.isSelected == rhs.isSelected
            && lhs.allowsFinalThumbnail == rhs.allowsFinalThumbnail
            && lhs.finalLoadID == rhs.finalLoadID
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Button(action: isSelecting ? toggleSelection : open) {
                    ExternalMediaThumbnailView(
                        item: item,
                        thumbnailService: thumbnailService,
                        displayMode: displayMode,
                        thumbnailWidth: thumbnailWidth,
                        showsMediaInfo: showsMediaInfo,
                        allowsFinalThumbnail: allowsFinalThumbnail,
                        finalLoadID: finalLoadID
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                if isSelecting || isHovering || isSelected {
                    Button(action: toggleSelection) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }

            if showsRecognitionInfo, item.mediaType != .video {
                PhotographyTagMenu(record: record, setManualTag: setManualTag)
                    .equatable()
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting(item.sourceURLs)
            }
        }
    }
}
