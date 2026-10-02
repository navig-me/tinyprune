import AppKit
import Foundation
import Testing
@testable import TinyPruneAgentCore

@Suite struct ManagedRootWorkspaceLifecycleTests {
    @Test func testVolumeEventsMatchOnlyRootsOnThatVolume() {
        let mounted = ManagedRootWorkspaceEvent.mounted(URL(fileURLWithPath: "/Volumes/Archive"))
        let unmounted = ManagedRootWorkspaceEvent.unmounted(URL(fileURLWithPath: "/Volumes/Archive"))
        for event in [mounted, unmounted] {
            #expect(event.affects(rootPaths: ["/Volumes/Archive"]))
            #expect(event.affects(rootPaths: ["/Users/me/Other", "/Volumes/Archive/Projects/build"]))
            #expect(!(event.affects(rootPaths: ["/Volumes/Archive-Old/Projects"])))
            #expect(!(event.affects(rootPaths: ["/Volumes/Archives/Projects"])))
            #expect(!(event.affects(rootPaths: ["/Volumes", "/Users/me/Projects"])))
            #expect(!(event.affects(rootPaths: [])))
        }
        #expect(mounted.affectedRootPaths(rootPaths: ["/Users/me/Other", "/Volumes/Archive/Project"]) == ["/Volumes/Archive/Project"])
    }

    @Test func testVolumeMatchingUsesNormalizedFilePathsAndHandlesRootVolume() {
        let event = ManagedRootWorkspaceEvent.mounted(URL(fileURLWithPath: "/Volumes/Archive/"))
        #expect(event.affects(rootPaths: ["/Volumes/Archive/Projects/../build"]))
        #expect(!(event.affects(rootPaths: ["/Volumes/Archive/../Other/build"])))
        #expect(ManagedRootWorkspaceEvent.mounted(URL(fileURLWithPath: "/")).affects(rootPaths: ["/Users/me/build"]))
        #expect(!(ManagedRootWorkspaceEvent.mounted(URL(string: "https://example.com/Volumes/Archive")!).affects(rootPaths: ["/Volumes/Archive/build"])))
    }

    @Test func testWakeRecoversEvenWithNoManagedRoots() {
        #expect(ManagedRootWorkspaceEvent.woke.affects(rootPaths: []))
        #expect(ManagedRootWorkspaceEvent.woke.affectedRootPaths(rootPaths: ["/Users/me/build"]) == ["/Users/me/build"])
        #expect(ManagedRootWorkspaceEvent.woke.affects(rootPaths: ["/Users/me/build"]))
    }

    @MainActor
    @Test func testNotificationDispatchStopAndRestartAreDeterministic() {
        let center = NotificationCenter()
        let recorder = WorkspaceEventRecorder()
        let lifecycle = ManagedRootWorkspaceLifecycle(center: center) { recorder.append($0) }
        let volume = URL(fileURLWithPath: "/Volumes/Archive")
        let info: [AnyHashable: Any] = [NSWorkspace.volumeURLUserInfoKey: volume]
        defer { lifecycle.stop() }

        lifecycle.start()
        lifecycle.start()
        center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: info)
        center.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: info)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(recorder.events == [.mounted(volume), .unmounted(volume), .woke])

        lifecycle.stop()
        center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: info)
        center.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: info)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(recorder.events == [.mounted(volume), .unmounted(volume), .woke])

        lifecycle.start()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(recorder.events == [.mounted(volume), .unmounted(volume), .woke, .woke])
    }

    @MainActor
    @Test func testMalformedAndUnrelatedNotificationsDoNotDispatchRecovery() {
        let center = NotificationCenter()
        let recorder = WorkspaceEventRecorder()
        let lifecycle = ManagedRootWorkspaceLifecycle(center: center) { recorder.append($0) }
        lifecycle.start()
        defer { lifecycle.stop() }

        center.post(name: NSWorkspace.didMountNotification, object: nil)
        center.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: "not a URL"])
        center.post(name: Notification.Name("unrelated-workspace-event"), object: nil)
        #expect(recorder.events == [])
    }
}

private final class WorkspaceEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ManagedRootWorkspaceEvent] = []

    var events: [ManagedRootWorkspaceEvent] { lock.withLock { recorded } }

    func append(_ event: ManagedRootWorkspaceEvent) {
        lock.withLock { recorded.append(event) }
    }
}
