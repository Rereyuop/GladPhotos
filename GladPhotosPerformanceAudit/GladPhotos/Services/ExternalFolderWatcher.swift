import CoreServices
import Foundation

@MainActor
final class ExternalFolderWatcher {
    private final class CallbackBox {
        let onChange: @MainActor () -> Void

        init(onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
        }
    }

    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?

    func start(folderURL: URL, onChange: @escaping @MainActor () -> Void) {
        stop()

        let box = CallbackBox(onChange: onChange)
        callbackBox = box
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, contextInfo, _, _, _, _ in
                guard let contextInfo else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(contextInfo).takeUnretainedValue()
                Task { @MainActor in box.onChange() }
            },
            &context,
            [folderURL.standardizedFileURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            flags
        ) else {
            callbackBox = nil
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackBox = nil
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
