// Token Tab — FSEvents folder watcher.
//
// Instead of polling the logs on a clock, we ask the OS to tell us when ~/.claude
// actually changes. Result: the bar updates the instant Claude Code writes a usage line,
// and idle CPU is ~0 (zero wakeups when nothing happens). Claude writes many lines per
// turn, so events are debounced into a single refresh.
//
// No network, no content: this only learns "something under this folder changed" and
// calls back — the re-read still goes through LogReader (metadata only).

import Foundation
import CoreServices

final class FolderWatcher {
    private let path: String
    private let onChange: () -> Void
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.tokentab.fsevents")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init(path: String, debounce: TimeInterval = 0.6, onChange: @escaping () -> Void) {
        self.path = path
        self.debounceInterval = debounce
        self.onChange = onChange
    }

    /// Returns false if the stream couldn't start (caller can fall back to a timer).
    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().scheduleDebounced()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer      // first event fires promptly, then coalesces
            | kFSEventStreamCreateFlagIgnoreSelf
        )
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx,
                                          [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          1.0,                       // OS-side latency (coalesce window)
                                          flags) else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s); return false
        }
        stream = s
        return true
    }

    /// Collapse a burst of file events into one callback.
    private func scheduleDebounced() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func stop() {
        pending?.cancel(); pending = nil
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
