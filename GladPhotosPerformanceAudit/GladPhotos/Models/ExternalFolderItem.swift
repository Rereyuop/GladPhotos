import Foundation

enum ExternalFolderAccessState: Hashable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }
}

struct ExternalFolderItem: Identifiable, Hashable {
    let id: UUID
    let url: URL?
    let displayName: String
    let isPersistent: Bool
    let accessState: ExternalFolderAccessState

    init(
        id: UUID = UUID(),
        url: URL?,
        displayName: String,
        isPersistent: Bool,
        accessState: ExternalFolderAccessState
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.isPersistent = isPersistent
        self.accessState = accessState
    }
}
