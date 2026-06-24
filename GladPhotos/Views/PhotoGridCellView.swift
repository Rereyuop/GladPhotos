import Photos
import SwiftUI

struct PhotoGridCellView: View, Equatable {
    let item: PhotoAssetItem
    let imageService: PhotoImageService
    let displayMode: PhotoGridDisplayMode
    let thumbnailWidth: CGFloat
    let isSelected: Bool
    let showsPhotoInfo: Bool
    let openDetail: () -> Void
    let toggleSelection: () -> Void
    let locateInApplePhotos: () -> Void
    let appeared: () -> Void
    let disappeared: () -> Void

    @State private var isHovered = false

    private var showsSelectionControl: Bool {
        isHovered || isSelected
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                openDetail()
            } label: {
                PhotoThumbnailView(
                    item: item,
                    imageService: imageService,
                    displayMode: displayMode,
                    thumbnailWidth: thumbnailWidth,
                    isSelected: isSelected,
                    showsSelectionState: showsSelectionControl,
                    showsPhotoInfo: showsPhotoInfo
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if showsSelectionControl {
                Button {
                    toggleSelection()
                } label: {
                    Color.clear
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "取消选择" : "选择照片")
                .help(isSelected ? "取消选择" : "选择照片")
                .pointingHandCursor()
                .padding(2)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear(perform: appeared)
        .onDisappear(perform: disappeared)
        .contextMenu {
            if ApplePhotosLocator.canLocate(item.asset) {
                Button("定位到 Apple 图库") {
                    locateInApplePhotos()
                }
            }
        }
    }

    static func == (lhs: PhotoGridCellView, rhs: PhotoGridCellView) -> Bool {
        lhs.item.localIdentifier == rhs.item.localIdentifier
            && lhs.item.asset.mediaType == rhs.item.asset.mediaType
            && lhs.item.asset.mediaSubtypes == rhs.item.asset.mediaSubtypes
            && lhs.item.asset.creationDate == rhs.item.asset.creationDate
            && lhs.item.asset.modificationDate == rhs.item.asset.modificationDate
            && lhs.item.asset.pixelWidth == rhs.item.asset.pixelWidth
            && lhs.item.asset.pixelHeight == rhs.item.asset.pixelHeight
            && lhs.displayMode == rhs.displayMode
            && lhs.thumbnailWidth == rhs.thumbnailWidth
            && lhs.isSelected == rhs.isSelected
            && lhs.showsPhotoInfo == rhs.showsPhotoInfo
            && lhs.imageService === rhs.imageService
    }
}
