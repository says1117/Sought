import Foundation

// App-only glue for the Robot tools screen. The lease-aware scan pieces are in ScanLease.swift.

/// Real time for the dwell. Returns early when the scan task is cancelled.
final class ScanSystemClock: ExploreClock {
    func now() -> Double { ProcessInfo.processInfo.systemUptime }
    func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
}

extension PoseSnapshotBox: ExplorePoseSource {}
