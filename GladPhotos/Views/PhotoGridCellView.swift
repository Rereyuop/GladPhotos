import Photos
import SwiftUI

struct PhotoGridCellView: View {
    let item: PhotoAssetItem
    let imageService: PhotoImageService
    let displayMode: PhotoGridDisplayMode
    let thumbnailWidth: CGFloat
    let preheatCoordinator: PhotoGridPreheatCoordinator
    let isSelected: Bool
    let showsPhotoInfo: Bool
    let openDetail: () -> Void
    let toggleSelection: () -> Void
    let locateInApplePhotos: () -> Void

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
        .onAppear {
            preheatCoordinator.assetAppeared(item.localIdentifier)
        }
        .onDisappear {
            preheatCoordinator.assetDisappeared(item.localIdentifier)
        }
        .contextMenu {
            if ApplePhotosLocator.canLocate(item.asset) {
                Button("定位到 Apple 图库") {
                    locateInApplePhotos()
                }
            }
        }
    }
}
