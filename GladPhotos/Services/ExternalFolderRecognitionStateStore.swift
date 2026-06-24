import Foundation
import Observation

struct ExternalFolderRecognitionState: Codable, Equatable {
    var hasRecognitionResults = false
    var showsRecognitionInfo = false
}

@Observable
@MainActor
final class ExternalFolderRecognitionStateStore {
    private var states: [UUID: ExternalFolderRecognitionState]
    private let defaults: UserDefaults
    private let persistenceKey = "externalFolderRecognitionStates.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(
               [UUID: ExternalFolderRecognitionState].self,
               from: data
           ) {
            states = decoded
        } else {
            states = [:]
        }
    }

    func state(for folderID: UUID) -> ExternalFolderRecognitionState {
        states[folderID] ?? ExternalFolderRecognitionState()
    }

    func recordResults(for folderID: UUID) {
        var state = state(for: folderID)
        state.hasRecognitionResults = true
        state.showsRecognitionInfo = true
        states[folderID] = state
        persist()
    }

    func setShowsRecognitionInfo(_ shows: Bool, for folderID: UUID) {
        var state = state(for: folderID)
        guard state.hasRecognitionResults else { return }
        state.showsRecognitionInfo = shows
        states[folderID] = state
        persist()
    }

    func remove(_ folderID: UUID) {
        states[folderID] = nil
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: persistenceKey)
    }
}
