import Foundation
import Testing
@testable import TinyPruneIPC

@Suite struct UpdateInstallationGateTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPruneUpdateGate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func inFlightTrashRejectsInstallationUntilPermitReleased() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let updater = UpdateInstallationGate(directory: directory)
        let agent = UpdateInstallationGate(directory: directory)
        var permit = try agent.acquireTrashPermit()
        #expect(permit != nil)
        #expect(throws: UpdateInstallationError.cleanupInProgress) {
            try updater.beginInstallation(targetVersion: "2", currentVersion: "1")
        }
        withExtendedLifetime(permit) {}
        permit = nil
        try updater.beginInstallation(targetVersion: "2", currentVersion: "1")
        #expect(try agent.acquireTrashPermit() == nil)
        try updater.finishInstallation()
        #expect(try agent.acquireTrashPermit() != nil)
    }

    @Test func markerSurvivesUpdaterExitAndOldAppCannotResumeCleanup() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let updater = UpdateInstallationGate(directory: directory)
            try updater.beginInstallation(targetVersion: "2", currentVersion: "1")
        }
        let nextLaunch = UpdateInstallationGate(directory: directory)
        #expect(try nextLaunch.hasPendingInstallation())
        #expect(try nextLaunch.acquireTrashPermit() == nil)
        #expect(throws: UpdateInstallationError.recoveryRequired) {
            try nextLaunch.recoverCompletedInstallation(currentVersion: "1")
        }
        #expect(throws: UpdateInstallationError.recoveryRequired) {
            try nextLaunch.recoverCompletedInstallation(currentVersion: "3")
        }
        #expect(try nextLaunch.acquireTrashPermit() == nil)
        #expect(try nextLaunch.recoverCompletedInstallation(currentVersion: "2"))
        #expect(try nextLaunch.acquireTrashPermit() != nil)
    }

    @Test func corruptMarkerFailsClosed() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("invalid metadata".utf8).write(to: directory.appendingPathComponent("update-installation.json"))
        let gate = UpdateInstallationGate(directory: directory)
        #expect(try gate.acquireTrashPermit() == nil)
        #expect(throws: (any Error).self) { try gate.recoverCompletedInstallation(currentVersion: "2") }
        #expect(try gate.hasPendingInstallation())
    }

    @Test func onlyInstallingOwnerCanCancelMarker() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UpdateInstallationGate(directory: directory)
        let other = UpdateInstallationGate(directory: directory)
        try owner.beginInstallation(targetVersion: "2", currentVersion: "1")
        try other.finishInstallation()
        #expect(try other.acquireTrashPermit() == nil)
        #expect(throws: UpdateInstallationError.cleanupInProgress) {
            try other.beginInstallation(targetVersion: "2", currentVersion: "1")
        }
        try owner.finishInstallation()
        #expect(try other.acquireTrashPermit() != nil)
    }

    @Test func resumedDownloadRetainsGateAndCannotSwitchTarget() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let original = UpdateInstallationGate(directory: directory)
            try original.beginInstallation(targetVersion: "2", currentVersion: "1")
        }
        let resumed = UpdateInstallationGate(directory: directory)
        #expect(try resumed.resumePendingInstallation(currentVersion: "1"))
        let agent = UpdateInstallationGate(directory: directory)
        #expect(try agent.acquireTrashPermit() == nil)
        try resumed.beginInstallation(targetVersion: "2", currentVersion: "1")
        #expect(throws: UpdateInstallationError.recoveryRequired) {
            try resumed.beginInstallation(targetVersion: "3", currentVersion: "1")
        }
        try resumed.finishInstallation()
        #expect(try agent.acquireTrashPermit() != nil)
    }

    @Test func failedAgentRestartCannotReopenCleanup() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let original = UpdateInstallationGate(directory: directory)
            try original.beginInstallation(targetVersion: "2", currentVersion: "1")
        }
        let replacement = UpdateInstallationGate(directory: directory)
        #expect(throws: UpdateInstallationError.recoveryRequired) {
            try replacement.recoverCompletedInstallation(currentVersion: "2") {
                #expect(try UpdateInstallationGate(directory: directory).acquireTrashPermit() == nil)
                throw UpdateInstallationError.recoveryRequired
            }
        }
        #expect(try replacement.hasPendingInstallation())
        #expect(try replacement.acquireTrashPermit() == nil)
        #expect(try replacement.recoverCompletedInstallation(currentVersion: "2"))
        #expect(try replacement.acquireTrashPermit() != nil)
    }
}
