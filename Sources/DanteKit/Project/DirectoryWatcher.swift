import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and reports changed paths in batches on the main
/// thread. Changes from the terminal, git or Claude all arrive here.
public final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @MainActor ([URL]) -> Void

    /// Starts watching. `latency` is how long FSEvents gathers changes before reporting them.
    public init(url: URL, latency: TimeInterval = 0.25, handler: @escaping @MainActor ([URL]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let urls = (0..<count).compactMap { (array[$0] as? String).map { URL(filePath: $0) } }
            MainActor.assumeIsolated { watcher.handler(urls) }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
