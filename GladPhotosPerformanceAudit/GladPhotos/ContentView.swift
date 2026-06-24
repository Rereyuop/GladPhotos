import Photos
import SwiftUI

enum LibrarySource: Hashable {
    case appleLibrary
    case externalFolder(UUID)
}

struct ContentView: View {
    @State private var photoLibrary = PhotoLibraryService()
    @State private var imageService = PhotoImageService()
    @State private var compressionService = PhotoCompressionService()
    @State private var externalFolderStore = ExternalFolderStore()
    @State private var externalScanner = ExternalMediaScanner()
    @State private var externalThumbnailService = ExternalThumbnailService()
    @State private var recognitionStateStore = ExternalFolderRecognitionStateStore()
    @State private var selection: LibrarySource = .appleLibrary
    @State private var selectedMonthDate = Date()
    @State private var selectedMonthFilter: Date?
    @State private var activeDay: Date?
    @State private var pendingScrollTarget: Date?
    @State private var dateIndexes: [LibrarySource: MediaDateIndex] = [:]
    @State private var externalItemsByFolder: [UUID: [ExternalMediaItem]] = [:]
    @State private var scrollRequestID = UUID()
    @State private var externalFolderError: String?

    private var daySections: [PhotoDaySection] {
        PhotoDaySection.make(from: photoLibrary.assets)
    }

    private var currentDateIndex: MediaDateIndex {
        dateIndexes[selection] ?? .empty
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $selection,
                selectedMonthDate: $selectedMonthDate,
                dateIndex: currentDateIndex,
                activeDay: $activeDay,
                pendingScrollTarget: $pendingScrollTarget,
                externalFolders: externalFolderStore.folders,
                selectAllPhotos: selectAllPhotos,
                selectMonth: { date in selectMonth(date) },
                selectToday: selectToday,
                selectExternalFolder: selectExternalFolder,
                reauthorizeExternalFolder: reauthorize,
                addExternalFolder: addExternalFolder,
                removeExternalFolder: removeExternalFolder
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 300)
        } detail: {
            detailContent
        }
        .task {
            await photoLibrary.checkAuthorization()
            updateAppleDateIndex()
            reconcileDateSelection(for: .appleLibrary)
        }
        .onChange(of: photoLibrary.allAssets) {
            updateAppleDateIndex()
            reconcileDateSelection(for: .appleLibrary)
        }
        .alert("外部文件夹操作失败", isPresented: externalFolderErrorBinding) {
            Button("好", role: .cancel) { externalFolderError = nil }
                .pointingHandCursor()
        } message: {
            Text(externalFolderError ?? "")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .externalFolder(let id):
            if let folder = externalFolderStore.folders.first(where: { $0.id == id }) {
                ExternalMediaGridView(
                    folder: folder,
                    scanner: externalScanner,
                    thumbnailService: externalThumbnailService,
                    recognitionStateStore: recognitionStateStore,
                    initialItems: externalItemsByFolder[folder.id] ?? [],
                    monthDate: selectedMonthFilter,
                    activeDay: $activeDay,
                    pendingScrollTarget: $pendingScrollTarget,
                    scrollRequestID: scrollRequestID,
                    onItemsChanged: { items in
                        updateExternalItems(items, for: folder.id)
                    },
                    reauthorize: { reauthorize(folder) },
                    removeFolder: { removeExternalFolder(folder) }
                )
                .id(folder)
            } else {
                ContentUnavailableView("文件夹已移除", systemImage: "folder")
            }
        case .appleLibrary:
            photoLibraryContent
        }
    }

    @ViewBuilder
    private var photoLibraryContent: some View {
        switch photoLibrary.authorizationState {
        case .unknown:
            ProgressView()
        case .notDetermined, .denied:
            PermissionView(
                authorizationState: photoLibrary.authorizationState,
                requestAuthorization: {
                    await photoLibrary.requestAuthorization()
                }
            )
        case .authorized:
            PhotoGridView(
                assets: photoLibrary.assets,
                imageService: imageService,
                daySections: daySections,
                title: navigationTitle,
                emptyTitle: emptyTitle,
                monthDate: selectedMonthFilter,
                activeDay: $activeDay,
                pendingScrollTarget: $pendingScrollTarget,
                scrollRequestID: scrollRequestID,
                deleteAssets: { items in
                    try await photoLibrary.deleteAssets(items)
                },
                compressAsset: { asset in
                    let result = try await compressionService.compress(asset)
                    let item = try photoLibrary.refreshAndFindAsset(
                        localIdentifier: result.localIdentifier
                    )
                    return CreatedCompressedPhoto(
                        item: item,
                        originalFileSize: result.originalFileSize,
                        compressedFileSize: result.compressedFileSize
                    )
                }
            )
        }
    }

    private var navigationTitle: String {
        switch selection {
        case .appleLibrary:
            guard let date = selectedMonthFilter else { return "Apple 图库" }
            return date.formatted(
                .dateTime.year().month(.wide).locale(.gladPhotosChinese)
            )
        case .externalFolder(let id):
            return externalFolderStore.folders.first(where: { $0.id == id })?.displayName
                ?? "外部文件夹"
        }
    }

    private var emptyTitle: String {
        switch selection {
        case .appleLibrary:
            return selectedMonthFilter == nil ? "没有照片" : "当月没有照片"
        case .externalFolder:
            return "没有媒体"
        }
    }

    private var externalFolderErrorBinding: Binding<Bool> {
        Binding(
            get: { externalFolderError != nil },
            set: { if !$0 { externalFolderError = nil } }
        )
    }

    private func selectAllPhotos() {
        selectSource(.appleLibrary)
    }

    private func addExternalFolder() {
        do {
            if let folder = try externalFolderStore.presentAddFolderPanel() {
                selectExternalFolder(folder)
            }
        } catch {
            externalFolderError = error.localizedDescription
        }
    }

    private func reauthorize(_ folder: ExternalFolderItem) {
        do {
            _ = try externalFolderStore.presentReauthorizationPanel(for: folder)
        } catch {
            externalFolderError = error.localizedDescription
        }
    }

    private func removeExternalFolder(_ folder: ExternalFolderItem) {
        recognitionStateStore.remove(folder.id)
        PhotographyTagStore.removePersistedRecords(for: folder.id)
        externalFolderStore.remove(folder)
        externalItemsByFolder[folder.id] = nil
        dateIndexes[.externalFolder(folder.id)] = nil
        if selection == .externalFolder(folder.id) {
            selectAllPhotos()
        }
    }

    private func selectMonth(_ date: Date) {
        guard currentDateIndex.containsMonth(date) else { return }
        selectedMonthDate = date
        selectedMonthFilter = date
        activeDay = nil
        pendingScrollTarget = nil
        if selection == .appleLibrary {
            photoLibrary.applyMonthFilter(date)
        }
        activeDay = currentDateIndex.days(in: date).max()
        scrollRequestID = UUID()
    }

    private func selectToday() {
        let today = Date()
        if currentDateIndex.containsMonth(today) {
            selectMonth(today)
            let day = Calendar.current.startOfDay(for: today)
            if currentDateIndex.days(in: today).contains(day) {
                activeDay = day
                pendingScrollTarget = day
            }
        } else if let latest = currentDateIndex.latestDate {
            selectMonth(latest)
        }
    }

    private func selectExternalFolder(_ folder: ExternalFolderItem) {
        selectSource(.externalFolder(folder.id))
    }

    private func selectSource(_ source: LibrarySource) {
        selection = source
        selectedMonthFilter = nil
        pendingScrollTarget = nil
        if source == .appleLibrary {
            photoLibrary.applyMonthFilter(nil)
        }
        reconcileDateSelection(for: source)
        scrollRequestID = UUID()
    }

    private func updateAppleDateIndex() {
        dateIndexes[.appleLibrary] = MediaDateIndex(
            dates: photoLibrary.allAssets.compactMap(\.asset.creationDate)
        )
    }

    private func updateExternalItems(_ items: [ExternalMediaItem], for folderID: UUID) {
        externalItemsByFolder[folderID] = items
        let source = LibrarySource.externalFolder(folderID)
        dateIndexes[source] = MediaDateIndex(dates: items.compactMap(\.displayDate))
        reconcileDateSelection(for: source)
    }

    private func reconcileDateSelection(for source: LibrarySource) {
        guard selection == source else { return }
        let index = dateIndexes[source] ?? .empty

        if let selectedMonthFilter, !index.containsMonth(selectedMonthFilter) {
            self.selectedMonthFilter = nil
            if source == .appleLibrary {
                photoLibrary.applyMonthFilter(nil)
            }
        }

        guard let latest = index.latestDate else {
            activeDay = nil
            pendingScrollTarget = nil
            return
        }

        if selectedMonthFilter == nil {
            selectedMonthDate = latest
        }
        let availableDays = index.days(in: selectedMonthDate)
        activeDay = availableDays.contains(activeDay ?? .distantPast)
            ? activeDay
            : availableDays.max()
        if let pendingScrollTarget, !availableDays.contains(pendingScrollTarget) {
            self.pendingScrollTarget = nil
        }
    }
}

#Preview {
    ContentView()
}
