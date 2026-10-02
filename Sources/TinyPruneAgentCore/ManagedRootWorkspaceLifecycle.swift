import AppKit
import Foundation

/// Workspace events require recovery, not an independent cleanup decision.
enum ManagedRootWorkspaceEvent: Sendable, Equatable {
    case mounted(URL)
    case unmounted(URL)
    case woke

    func affectedRootPaths(rootPaths: [String]) -> [String] {
        switch self {
        case .woke:
            return rootPaths
        case .mounted(let volume), .unmounted(let volume):
            guard volume.isFileURL else { return [] }
            let volumePath = volume.standardizedFileURL.path
            let prefix = volumePath == "/" ? "/" : volumePath + "/"
            return rootPaths.filter { path in
                let rootPath = URL(fileURLWithPath: path).standardizedFileURL.path
                return rootPath == volumePath || rootPath.hasPrefix(prefix)
            }
        }
    }

    func affects(rootPaths: [String]) -> Bool {
        if case .woke = self { return true }
        return !affectedRootPaths(rootPaths: rootPaths).isEmpty
    }
}

/// Kept on the main actor because NSWorkspace is an AppKit lifecycle source.
@MainActor
final class ManagedRootWorkspaceLifecycle {
    private let center: NotificationCenter
    private let receive: @Sendable (ManagedRootWorkspaceEvent) -> Void
    private var tokens: [NSObjectProtocol] = []

    init(
        center: NotificationCenter? = nil,
        receive: @escaping @Sendable (ManagedRootWorkspaceEvent) -> Void
    ) {
        self.center = center ?? NSWorkspace.shared.notificationCenter
        self.receive = receive
    }

    func start() {
        guard tokens.isEmpty else { return }
        let receive = receive
        tokens = [
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { notification in
                guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                receive(.mounted(volume))
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { notification in
                guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                receive(.unmounted(volume))
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                receive(.woke)
            },
        ]
    }

    func stop() {
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}

/// Actor reentrancy must not let a queued recovery recreate watches after stop.
actor ManagedRootRuntimeOperationGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
