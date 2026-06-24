import Photos
import SwiftUI

struct PhotoDaySection: Identifiable {
    let date: Date
    let assets: [PhotoAssetItem]

    var id: Date { date }

    @MainActor
    static func make(from assets: [PhotoAssetItem]) -> [PhotoDaySection] {
        let calendar = Calendar.current
        let datedAssets = assets.filter { $0.asset.creationDate != nil }
        let groupedAssets = Dictionary(grouping: datedAssets) { item in
            calendar.startOfDay(for: item.asset.creationDate ?? .distantPast)
        }

        return groupedAssets.map { date, items in
            PhotoDaySection(
                date: date,
                assets: items.sorted {
                    ($0.asset.creationDate ?? .distantPast)
                        < ($1.asset.creationDate ?? .distantPast)
                }
            )
        }
        .sorted { $0.date < $1.date }
    }
}

struct PhotoGridView: View {
    let assets: [PhotoAssetItem]
    let imageService: PhotoImageService
    let daySections: [PhotoDaySection]
    let undatedAssets: [PhotoAssetItem]
    let daySectionIDs: [Date]
    let daySectionIndexByID: [Date: Int]
    let title: String
    let emptyTitle: String
    let monthDate: Date?
    @Binding var activeDay: Date?
    @Binding var pendingScrollTarget: Date?
    let scrollRequestID: UUID
    let deleteAssets: ([PhotoAssetItem]) async throws -> Void
    let compressAsset: (PHAsset) async throws -> CreatedCompressedPhoto

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var displayMode: PhotoGridDisplayMode = .originalRatio
    @State private var thumbnailWidth: CGFloat = 128
    @State private var isSelecting = false
    @State private var selectedIdentifiers = Set<String>()
    @State private var deletionError: String?
    @State private var detailItem: PhotoAssetItem?
    @State private var lastViewedIdentifier: String?
    @State private var showsPhotoInfo = false
    @State private var locationError: String?
    @State private var nativeStats = NativePhotoGridStats()

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "photo")
                } else {
                    NativePhotoCollectionView(
                        daySections: daySections,
                        undatedAssets: undatedAssets,
                        allAssets: assets,
                        imageService: imageService,
                        displayMode: displayMode,
                        thumbnailWidth: thumbnailWidth,
                        showsPhotoInfo: showsPhotoInfo,
                        isSelecting: $isSelecting,
                        reduceMotion: reduceMotion,
                        scrollRequestID: scrollRequestID,
                        selectedIdentifiers: $selectedIdentifiers,
                        activeDay: $activeDay,
                        pendingScrollTarget: $pendingScrollTarget,
                        stats: $nativeStats,
                        openDetail: { item in
                            lastViewedIdentifier = item.localIdentifier
                            detailItem = item
                        },
                        locateInApplePhotos: locateInApplePhotos,
                        selectAll: selectAll,
                        invertSelection: invertSelection(in:)
                    )
                }
            }
            .navigationTitle(title)
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .principal) {
                        selectionTitleBarContent
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button(showsPhotoInfo ? "隐藏信息" : "显示信息") {
                        showsPhotoInfo.toggle()
                    }
                    .help("显示或隐藏照片时间和资源大小")
                    .pointingHandCursor()

                    selectionControls

                    Button(displayMode.title) {
                        displayMode = displayMode == .square
                            ? .originalRatio
                            : .square
                    }
                    .help("切换照片显示比例")
                    .pointingHandCursor()
                }
            }
            .focusedSceneValue(\.photoGridThumbnailWidth, $thumbnailWidth)
            .onExitCommand {
                guard isSelecting else { return }
                cancelSelection()
            }
            .overlay {
                if let item = detailItem {
                    PhotoDetailView(
                        item: item,
                        assets: assets,
                        imageService: imageService,
                        deleteAssets: deleteAssets,
                        compressAsset: compressAsset,
                        onCurrentItemChanged: { item in
                            lastViewedIdentifier = item.localIdentifier
                        },
                        onClose: { detailItem = nil }
                    )
                    .ignoresSafeArea()
                    .zIndex(100)
                }
            }
            .alert("删除失败", isPresented: deletionErrorBinding) {
                Button("好", role: .cancel) {
                    deletionError = nil
                }
                .pointingHandCursor()
            } message: {
                Text(deletionError ?? "")
            }
            .alert(ApplePhotosLocator.failureMessage, isPresented: locationErrorBinding) {
                Button("好", role: .cancel) {
                    locationError = nil
                }
                .pointingHandCursor()
            }
            .onChange(of: assets) {
                let currentIdentifiers = Set(assets.map(\.localIdentifier))
                selectedIdentifiers.formIntersection(currentIdentifiers)
                if assets.isEmpty {
                    isSelecting = false
                    selectedIdentifiers.removeAll()
                }
            }
        }
    }

    private var selectionTitleBarContent: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.headline)

            Button(action: {}) {
                Text("已选择 \(selectedIdentifiers.count) 项")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(selectedIdentifiers.count)))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.2),
                value: selectedIdentifiers.count
            )
            .accessibilityLabel("已选择 \(selectedIdentifiers.count) 项")
        }
    }

    @ViewBuilder
    private var selectionControls: some View {
        if isSelecting {
            Button("删除", role: .destructive) {
                Task {
                    await deleteSelectedAssets()
                }
            }
            .disabled(selectedIdentifiers.isEmpty)
            .pointingHandCursor()

            Button("取消") {
                cancelSelection()
            }
            .pointingHandCursor()
        } else {
            Button("选择") {
                isSelecting = true
            }
            .pointingHandCursor()
        }
    }

    private var deletionErrorBinding: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { isPresented in
                if !isPresented {
                    deletionError = nil
                }
            }
        )
    }

    private var locationErrorBinding: Binding<Bool> {
        Binding(
            get: { locationError != nil },
            set: { isPresented in
                if !isPresented {
                    locationError = nil
                }
            }
        )
    }

    private func selectAll(_ items: [PhotoAssetItem]) {
        isSelecting = true
        selectedIdentifiers.formUnion(items.map(\.localIdentifier))
    }

    private func invertSelection(in items: [PhotoAssetItem]) {
        isSelecting = true
        for identifier in items.map(\.localIdentifier) {
            if selectedIdentifiers.contains(identifier) {
                selectedIdentifiers.remove(identifier)
            } else {
                selectedIdentifiers.insert(identifier)
            }
        }
    }

    private func cancelSelection() {
        isSelecting = false
        selectedIdentifiers.removeAll()
    }

    private func locateInApplePhotos(_ item: PhotoAssetItem) {
        guard ApplePhotosLocator.open(item.asset) else {
            locationError = ApplePhotosLocator.failureMessage
            return
        }
    }

    private func deleteSelectedAssets() async {
        let itemsToDelete = assets.filter {
            selectedIdentifiers.contains($0.localIdentifier)
        }
        let selectedIdentifiersSnapshot = selectedIdentifiers

        guard !itemsToDelete.isEmpty else {
            return
        }

        do {
            try await deleteAssets(itemsToDelete)
            selectedIdentifiers.removeAll()
            isSelecting = false
        } catch {
            selectedIdentifiers = selectedIdentifiersSnapshot
            if !error.isPhotoLibraryUserCancellation {
                deletionError = error.localizedDescription
            }
        }
    }
}
