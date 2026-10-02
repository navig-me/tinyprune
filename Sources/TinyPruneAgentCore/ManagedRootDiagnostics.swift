import Foundation

public struct ManagedRootDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public let fullTreeScans: UInt64
    public let recoveryCount: UInt64
    public let indexedEntries: UInt64
    public let eventQueueHighWater: Int
    public let persistenceBatchHighWater: Int
    public let databaseWriteBatches: UInt64
    public let databaseRowsWritten: UInt64
    public let lastScanDurationSeconds: Double
    public let scanCPUSeconds: Double
    public let peakResidentBytes: UInt64
}

final class ManagedRootDiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var fullTreeScans: UInt64 = 0
    private var recoveryCount: UInt64 = 0
    private var indexedEntries: UInt64 = 0
    private var eventQueueHighWater = 0
    private var persistenceBatchHighWater = 0
    private var databaseWriteBatches: UInt64 = 0
    private var databaseRowsWritten: UInt64 = 0
    private var lastScanDurationSeconds = 0.0
    private var scanCPUSeconds = 0.0
    private var peakResidentBytes: UInt64 = 0

    func recordQueueDepth(_ depth: Int) {
        lock.withLock { eventQueueHighWater = max(eventQueueHighWater, depth) }
    }

    func recordRecovery() {
        lock.withLock { recoveryCount &+= 1 }
    }

    func recordPersistenceBatch(_ rows: Int) {
        guard rows > 0 else { return }
        lock.withLock {
            persistenceBatchHighWater = max(persistenceBatchHighWater, rows)
            databaseWriteBatches &+= 1
            databaseRowsWritten &+= UInt64(rows)
        }
    }

    func recordScan(entries: UInt64, duration: Double, cpu: Double, fullTree: Bool, residentBytes: UInt64) {
        lock.withLock {
            if fullTree { fullTreeScans &+= 1 }
            indexedEntries &+= entries
            lastScanDurationSeconds = duration
            scanCPUSeconds += cpu
            peakResidentBytes = max(peakResidentBytes, residentBytes)
        }
    }

    func snapshot() -> ManagedRootDiagnosticsSnapshot {
        lock.withLock {
            ManagedRootDiagnosticsSnapshot(
                fullTreeScans: fullTreeScans,
                recoveryCount: recoveryCount,
                indexedEntries: indexedEntries,
                eventQueueHighWater: eventQueueHighWater,
                persistenceBatchHighWater: persistenceBatchHighWater,
                databaseWriteBatches: databaseWriteBatches,
                databaseRowsWritten: databaseRowsWritten,
                lastScanDurationSeconds: lastScanDurationSeconds,
                scanCPUSeconds: scanCPUSeconds,
                peakResidentBytes: peakResidentBytes
            )
        }
    }
}
