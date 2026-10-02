import Darwin
import Foundation
import Testing
@testable import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPrunePersistence

extension Tag {
    @Tag static var benchmark: Self
}

@Suite(.tags(.benchmark)) struct PhaseTwoBenchmarkTests {
    @Test(.tags(.benchmark)) func test100kIndexBenchmarkAndSixtySecondIdleSoak() async throws {
        let fileCount = ProcessInfo.processInfo.environment["TINYPRUNE_BENCHMARK_ENTRIES"].flatMap(Int.init) ?? 100_000
        let soakSeconds = ProcessInfo.processInfo.environment["TINYPRUNE_IDLE_SOAK_SECONDS"].flatMap(UInt64.init) ?? 60
        #expect(fileCount > 0)

        let fileManager = FileManager.default
        let identifier = UUID().uuidString
        let rootURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-PhaseTwo-\(identifier)", isDirectory: true)
        let databaseURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-PhaseTwo-\(identifier).sqlite3")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: rootURL)
            for suffix in ["", "-wal", "-shm"] {
                try? fileManager.removeItem(atPath: databaseURL.path + suffix)
            }
        }
        try makeFixture(root: rootURL, fileCount: fileCount)

        let root = try ManagedRoot(
            displayName: rootURL.lastPathComponent,
            path: rootURL.standardizedFileURL.path,
            bookmarkData: Data([1])
        )
        let matcher = try ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["**/*.dat"])
        let rule = try LifetimeRule(
            name: "Phase 2 benchmark",
            scope: RuleScope(path: root.path, recursive: true),
            matcher: matcher,
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 365 * 24 * 60 * 60),
            action: .trashItem,
            state: .active
        )
        let store = try SQLiteSafetyStore(databaseURL: databaseURL)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let runtime = ManagedRootAgentRuntime(store: store, resolver: { _ in rootURL })
        let scanStarted = ProcessInfo.processInfo.systemUptime
        let expectedEntries = UInt64(fileCount + directoryCount(for: fileCount))

        do {
            try await runtime.start()
            var diagnostics = await runtime.diagnosticsSnapshot()
            let scanDeadline = scanStarted + 300
            while diagnostics.fullTreeScans == 0 || diagnostics.indexedEntries < expectedEntries {
                guard ProcessInfo.processInfo.systemUptime < scanDeadline else {
                    throw PhaseTwoBenchmarkFailure.indexTimeout
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                diagnostics = await runtime.diagnosticsSnapshot()
            }
            let scanWallSeconds = ProcessInfo.processInfo.systemUptime - scanStarted
            let scansBeforeSoak = diagnostics.fullTreeScans
            let cpuBeforeSoak = processCPUSeconds()
            try await Task.sleep(nanoseconds: soakSeconds * 1_000_000_000)
            let idleCPUSeconds = max(0, processCPUSeconds() - cpuBeforeSoak)
            let afterSoak = await runtime.diagnosticsSnapshot()
            await runtime.stop()

            let report: [String: Any] = [
                "entryCount": fileCount,
                "indexedEntries": diagnostics.indexedEntries,
                "scanWallSeconds": scanWallSeconds,
                "scanDurationSeconds": diagnostics.lastScanDurationSeconds,
                "scanCPUSeconds": diagnostics.scanCPUSeconds,
                "peakResidentBytes": diagnostics.peakResidentBytes,
                "idleSoakSeconds": soakSeconds,
                "idleCPUSeconds": idleCPUSeconds,
                "fullTreeScansDuringIdle": afterSoak.fullTreeScans - scansBeforeSoak,
                "eventQueueHighWater": diagnostics.eventQueueHighWater,
                "persistenceBatchHighWater": diagnostics.persistenceBatchHighWater,
                "databaseWriteBatches": diagnostics.databaseWriteBatches,
                "databaseRowsWritten": diagnostics.databaseRowsWritten,
                "recoveryCount": diagnostics.recoveryCount
            ]
            let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: reportData, as: UTF8.self))

            #expect(scanWallSeconds <= 300)
            #expect(diagnostics.peakResidentBytes <= 512 * 1024 * 1024)
            #expect(idleCPUSeconds <= 0.5)
            #expect(afterSoak.fullTreeScans == scansBeforeSoak)
            #expect(diagnostics.eventQueueHighWater <= 512)
            #expect(diagnostics.persistenceBatchHighWater <= 256)
            #expect(diagnostics.databaseRowsWritten >= UInt64(fileCount))
        } catch {
            await runtime.stop()
            throw error
        }
    }

    private func makeFixture(root: URL, fileCount: Int) throws {
        let fileManager = FileManager.default
        let numberOfDirectories = directoryCount(for: fileCount)
        let filesPerDirectory = (fileCount + numberOfDirectories - 1) / numberOfDirectories
        for directoryIndex in 0..<numberOfDirectories {
            let directory = root.appendingPathComponent(String(format: "group-%04d", directoryIndex), isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let start = directoryIndex * filesPerDirectory
            let end = min(start + filesPerDirectory, fileCount)
            for fileIndex in start..<end {
                let path = directory.appendingPathComponent(String(format: "item-%06d.dat", fileIndex)).path
                guard fileManager.createFile(atPath: path, contents: Data()) else {
                    throw PhaseTwoBenchmarkFailure.fixtureCreation(path)
                }
            }
        }
    }

    private func directoryCount(for fileCount: Int) -> Int {
        max(1, (fileCount + 999) / 1_000)
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}

private enum PhaseTwoBenchmarkFailure: Error {
    case fixtureCreation(String)
    case indexTimeout
}
