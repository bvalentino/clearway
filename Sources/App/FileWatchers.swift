@preconcurrency import Dispatch
import Foundation

/// The single door every file-system `DispatchSource` in the app goes through.
enum FileWatchers {
    /// The default mask catches atomic file operations (write-to-temp → rename)
    /// and in-place rewrites that `.write` alone can miss. Directory watchers that only
    /// care about entries appearing and disappearing pass `.write` instead.
    static let defaultWatchMask: DispatchSource.FileSystemEvent =
        [.write, .attrib, .rename, .link, .extend, .delete]

    /// Builds a file-system watcher.
    ///
    /// `nonisolated` is load-bearing, and so is routing every watcher through here.
    /// `setEventHandler`/`setCancelHandler` take a `@convention(block)` closure, so a literal
    /// written inside an actor-isolated method inherits that isolation and gets a
    /// `swift_task_isCurrentExecutor` prologue — which traps when libdispatch runs it on the
    /// utility queue below. Formed here, outside the actor, the blocks carry no isolation, and
    /// `handler` is a plain Swift function type the compiler checks statically instead.
    nonisolated static func makeWatcher(
        path: String,
        eventMask: DispatchSource.FileSystemEvent = defaultWatchMask,
        handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: eventMask,
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
