import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
@MainActor
final class ExternalFolderStore {
    private(set) var folders: [ExternalFolderItem] = []

    private let defaults: UserDefaults
    private let persistenceKey = "externalFolderBookmarks.v1"
    private var accessedURLs: [UUID: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreFolders()
    }

    isolated deinit {
        for url in accessedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
    }

    @discardableResult
    func presentAddFolderPanel() throws -> ExternalFolderItem? {
        let panel = makeOpenPanel(
            message: "选择要添加到 GladPhotos 的文件夹",
            prompt: "添加"
        )
        let rememberCheckbox = NSButton(
            checkboxWithTitle: "记住此文件夹",
            target: nil,
            action: nil
        )
        rememberCheckbox.state = .on
        panel.accessoryView = rememberCheckbox

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        return try addFolder(
            at: url,
            remember: rememberCheckbox.state == .on
        )
    }

    @discardableResult
    func presentReauthorizationPanel(for folder: ExternalFolderItem) throws -> Bool {
        let panel = makeOpenPanel(
            message: "重新选择“\(folder.displayName)”以恢复访问权限",
            prompt: "重新授权"
        )
        panel.directoryURL = folder.url?.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        try replaceAuthorization(for: folder.id, with: url)
        return true
    }

    func remove(_ folder: ExternalFolderItem) {
        stopAccessing(folder.id)
        folders.removeAll { $0.id == folder.id }
        savePersistentFolders()
    }

    private func addFolder(at url: URL, remember: Bool) throws -> ExternalFolderItem {
        let normalizedURL = url.standardizedFileURL
        if let existing = folders.first(where: {
            $0.url?.standardizedFileURL == normalizedURL
        }) {
            return existing
        }

        let id = UUID()
        beginAccessing(normalizedURL, id: id)

        do {
            let bookmarkData = remember ? try makeBookmark(for: normalizedURL) : nil
            let folder = ExternalFolderItem(
                id: id,
                url: normalizedURL,
                displayName: normalizedURL.lastPathComponent,
                isPersistent: remember,
                accessState: readableState(for: normalizedURL)
            )
            folders.append(folder)

            if let bookmarkData {
                saveBookmark(
                    PersistedFolder(
                        id: id,
                        displayName: folder.displayName,
                        bookmarkData: bookmarkData
                    )
                )
            }
            return folder
        } catch {
            stopAccessing(id)
            throw error
        }
    }

    private func replaceAuthorization(for id: UUID, with url: URL) throws {
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            return
        }

        let oldFolder = folders[index]
        let normalizedURL = url.standardizedFileURL
        beginAccessing(normalizedURL, id: id)

        do {
            let bookmarkData = try makeBookmark(for: normalizedURL)
            let replacement = ExternalFolderItem(
                id: id,
                url: normalizedURL,
                displayName: normalizedURL.lastPathComponent,
                isPersistent: true,
                accessState: readableState(for: normalizedURL)
            )
            folders[index] = replacement
            upsertBookmark(
                PersistedFolder(
                    id: id,
                    displayName: replacement.displayName,
                    bookmarkData: bookmarkData
                )
            )
        } catch {
            stopAccessing(id)
            if let oldURL = oldFolder.url, oldFolder.accessState.isAvailable {
                beginAccessing(oldURL, id: id)
            }
            folders[index] = oldFolder
            throw error
        }
    }

    private func restoreFolders() {
        let persistedFolders = loadBookmarks()
        folders = persistedFolders.map { persisted in
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: persisted.bookmarkData,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                guard !isStale else {
                    return ExternalFolderItem(
                        id: persisted.id,
                        url: url,
                        displayName: persisted.displayName,
                        isPersistent: true,
                        accessState: .unavailable("文件夹权限已失效，请重新授权")
                    )
                }

                beginAccessing(url, id: persisted.id)
                return ExternalFolderItem(
                    id: persisted.id,
                    url: url,
                    displayName: persisted.displayName,
                    isPersistent: true,
                    accessState: readableState(for: url)
                )
            } catch {
                return ExternalFolderItem(
                    id: persisted.id,
                    url: nil,
                    displayName: persisted.displayName,
                    isPersistent: true,
                    accessState: .unavailable("无法恢复文件夹权限，请重新授权")
                )
            }
        }
    }

    private func beginAccessing(_ url: URL, id: UUID) {
        stopAccessing(id)
        if url.startAccessingSecurityScopedResource() {
            accessedURLs[id] = url
        }
    }

    private func stopAccessing(_ id: UUID) {
        guard let url = accessedURLs.removeValue(forKey: id) else {
            return
        }
        url.stopAccessingSecurityScopedResource()
    }

    private func readableState(for url: URL) -> ExternalFolderAccessState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path)
        else {
            return .unavailable("文件夹不存在或不可访问")
        }
        return .available
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func makeOpenPanel(message: String, prompt: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.folder]
        return panel
    }

    private func saveBookmark(_ folder: PersistedFolder) {
        var persisted = loadBookmarks()
        persisted.append(folder)
        writeBookmarks(persisted)
    }

    private func upsertBookmark(_ folder: PersistedFolder) {
        var persisted = loadBookmarks()
        persisted.removeAll { $0.id == folder.id }
        persisted.append(folder)
        writeBookmarks(persisted)
    }

    private func savePersistentFolders() {
        let retainedIDs = Set(folders.filter(\.isPersistent).map(\.id))
        writeBookmarks(loadBookmarks().filter { retainedIDs.contains($0.id) })
    }

    private func loadBookmarks() -> [PersistedFolder] {
        guard let data = defaults.data(forKey: persistenceKey) else {
            return []
        }
        return (try? JSONDecoder().decode([PersistedFolder].self, from: data)) ?? []
    }

    private func writeBookmarks(_ folders: [PersistedFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else {
            return
        }
        defaults.set(data, forKey: persistenceKey)
    }
}

private struct PersistedFolder: Codable {
    let id: UUID
    let displayName: String
    let bookmarkData: Data
}
