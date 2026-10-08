import CoreServices
import Foundation

public struct ManagedRootEvent: Sendable {
    public let paths: [String]
    public let flags: [FSEventStreamEventFlags]
    public let eventIDs: [FSEventStreamEventId]
    public let requiresRecovery: Bool

    public init(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        eventIDs: [FSEventStreamEventId],
        requiresRecovery: Bool = false
    ) {
        self.paths = paths
        self.flags = flags
        self.eventIDs = eventIDs
        self.requiresRecovery = requiresRecovery
    }
}

/// Owned jointly by the stream (via retain/release callbacks) and `ManagedRootEventStream`, so an in-flight
/// callback can never observe a freed context. `deactivate()` makes later deliveries no-ops.
private final class EventCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ManagedRootEvent) -> Void)?

    init(handler: @escaping @Sendable (ManagedRootEvent) -> Void) { self.handler = handler }

    func deliver(_ event: ManagedRootEvent) {
        let current = lock.withLock { handler }
        current?(event)
    }

    func deactivate() {
        lock.withLock { handler = nil }
    }
}

public final class ManagedRootEventStream: @unchecked Sendable {
    private let stream: FSEventStreamRef
    private let context: EventCallbackContext
    private let queue: DispatchQueue
    private let stopLock = NSLock()
    private var stopped = false
    public init(
        rootPath: String,
        since eventID: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latency: CFTimeInterval = 0.25,
        handler: @escaping @Sendable (ManagedRootEvent) -> Void
    ) throws {
        let contextValue = EventCallbackContext(handler: handler)
        // The stream retains/releases `info` itself; it stays valid until the stream is deallocated.
        var streamContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(contextValue).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<EventCallbackContext>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<EventCallbackContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let watchedPaths = [rootPath] as CFArray
        // WatchRoot delivers RootChanged when the root itself is renamed, moved or deleted.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.receiveEvents,
            &streamContext,
            watchedPaths,
            eventID,
            latency,
            flags
        ) else {
            throw ManagedRootEventError.streamCreationFailed(rootPath)
        }
        self.stream = stream
        self.context = contextValue
        self.queue = DispatchQueue(label: "com.navig-me.tinyprune.fsevents.\(UUID().uuidString)", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            // Mark stopped first so `deinit` does not release the stream a second time.
            stopLock.withLock { stopped = true }
            contextValue.deactivate()
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw ManagedRootEventError.streamStartFailed(rootPath)
        }
    }

    public func stop() {
        let shouldStop = stopLock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        context.deactivate()
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }

    private static let maximumEventsPerCallback = 512

    private static let receiveEvents: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, eventIDs in
        guard let info else { return }
        let callback = Unmanaged<EventCallbackContext>.fromOpaque(info).takeUnretainedValue()
        if eventCount > maximumEventsPerCallback {
            callback.deliver(ManagedRootEvent(
                paths: [],
                flags: [],
                eventIDs: [eventIDs[eventCount - 1]],
                requiresRecovery: true
            ))
            return
        }
        let rawPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var paths: [String] = []
        var flags: [FSEventStreamEventFlags] = []
        var ids: [FSEventStreamEventId] = []
        paths.reserveCapacity(eventCount)
        flags.reserveCapacity(eventCount)
        ids.reserveCapacity(eventCount)

        for index in 0..<eventCount {
            paths.append(String(cString: rawPaths[index]))
            flags.append(eventFlags[index])
            ids.append(eventIDs[index])
        }
        callback.deliver(ManagedRootEvent(paths: paths, flags: flags, eventIDs: ids))
    }
}

public enum ManagedRootEventError: Error, Equatable, Sendable {
    case streamCreationFailed(String)
    case streamStartFailed(String)
}
