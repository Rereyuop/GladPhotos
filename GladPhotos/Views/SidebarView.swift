import AppKit
import SwiftUI

struct SidebarView: View {
    @Binding var selection: LibrarySource
    @Binding var selectedMonthDate: Date
    let dateIndex: MediaDateIndex
    @Binding var activeDay: Date?
    @Binding var pendingScrollTarget: Date?
    let externalFolders: [ExternalFolderItem]

    let selectAllPhotos: () -> Void
    let selectMonth: (Date) -> Void
    let selectToday: () -> Void
    let selectExternalFolder: (ExternalFolderItem) -> Void
    let reauthorizeExternalFolder: (ExternalFolderItem) -> Void
    let addExternalFolder: () -> Void
    let removeExternalFolder: (ExternalFolderItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            librarySection

            Divider()

            CalendarFilterView(
                selectedMonthDate: $selectedMonthDate,
                dateIndex: dateIndex,
                activeDay: $activeDay,
                pendingScrollTarget: $pendingScrollTarget,
                onMonthSelected: selectMonth,
                onToday: selectToday
            )
            .padding()
        }
        .navigationTitle("照片")
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            libraryRow(
                title: "Apple 图库",
                systemImage: "photo.on.rectangle.angled",
                isSelected: selection == .appleLibrary,
                action: selectAllPhotos
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(externalFolders) { folder in
                        externalFolderRow(folder)
                    }
                }
            }

            Divider()
                .padding(.horizontal, 8)

            Button(action: addExternalFolder) {
                Label("添加外部文件夹", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity)
        .layoutPriority(1)
    }

    private func externalFolderRow(_ folder: ExternalFolderItem) -> some View {
        libraryRow(
            title: folder.displayName,
            systemImage: folder.accessState.isAvailable
                ? "folder"
                : "folder.badge.questionmark",
            iconColor: folder.accessState.isAvailable ? nil : .red,
            isSelected: selection == .externalFolder(folder.id),
            action: { selectExternalFolder(folder) }
        )
        .help(folder.displayName)
        .contextMenu {
            Button("移除文件夹", role: .destructive) {
                removeExternalFolder(folder)
            }
            .pointingHandCursor()

            Button("在 Finder 中显示") {
                guard let folderURL = folder.url else { return }
                NSWorkspace.shared.activateFileViewerSelecting([folderURL])
            }
            .disabled(!folderExists(folder.url))
            .pointingHandCursor()
        }
    }

    private func folderExists(_ url: URL?) -> Bool {
        guard let url else { return false }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func libraryRow(
        title: String,
        systemImage: String,
        iconColor: Color? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(
                        iconColor ?? (isSelected ? Color.white : Color.primary)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }

}
