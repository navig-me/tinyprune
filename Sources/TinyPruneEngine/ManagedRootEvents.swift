import CoreServices
import Foundation

public struct ManagedRootEvent: Sendable {
    public let paths: [String]
    public let flags: [FSEventStreamEventFlags]
    public let eventIDs: [FSEventStreamEventId]

    public init(paths: [String], flags: [FSEventStreamEventFlags], eventIDs: [FSEventStreamEventId]) {
        self.paths = paths
        self.flags = flags
        self.eventIDs = eventIDs
    }
}

private final class EventCallbackContext: @unchecked Sendable {
    let handler: @Sendable (ManagedRootEvent) -> Void
    init(handler: @escaping @Sendable (ManagedRootEvent) -> Void) { self.handler = handler }
}

public final class ManagedRootEventStream: @unchecked Sendable {
    private let stream: FSEventStreamRef
    private let context: Unmanaged<EventCallbackContext>
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
        let retainedContext = Unmanaged.passRetained(contextValue)
        var context = FSEventStreamContext(
            version: 0,
            info: retainedContext.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let watchedPaths = [rootPath] as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.receiveEvents,
            &context,
            watchedPaths,
            eventID,
            latency,
            flags
        ) else {
            retainedContext.release()
            throw ManagedRootEventError.streamCreationFailed(rootPath)
        }
        self.stream = stream
        self.context = retainedContext
        self.queue = DispatchQueue(label: "com.navig-me.tinyprune.fsevents.\(UUID().uuidString)", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            retainedContext.release()
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
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        context.release()
    }

    deinit { stop() }

    private static let receiveEvents: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, eventIDs in
        guard let info else { return }
        let callback = Unmanaged<EventCallbackContext>.fromOpaque(info).takeUnretainedValue()
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
        callback.handler(ManagedRootEvent(paths: paths, flags: flags, eventIDs: ids))
    }
}

public enum ManagedRootEventError: Error, Equatable, Sendable {
    case streamCreationFailed(String)
    case streamStartFailed(String)
}
