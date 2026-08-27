// FSWatcher.swift — thin wrapper around FSEvents that fires a debounced
// callback when the watched directory changes. We watch the Voice Memos
// Recordings dir; new memos (and the DB's -wal updates) land there.

import Foundation
import CoreServices

final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "voice-memos-ingest.fswatcher")
    private var pendingWork: DispatchWorkItem?
    private let onChange: @Sendable () -> Void

    init(path: String, debounce: TimeInterval = 2.0, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleDebounced()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce, flags
        ) else {
            FileHandle.standardError.write("FSWatcher: failed to create stream\n".data(using: .utf8)!)
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Coalesce bursts of FS events into a single callback.
    private func scheduleDebounced() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
