import Foundation
import SwiftUI

// App-only glue: connects SelfTestEngine to DriveLink, PoseTracker and ObstacleGuard, writes the JSONL log.
// NOT compiled or run by the author: no Xcode on the machine that wrote it. Real iPhone + rover only.

/// Appends JSONL records, including manual measurements entered after the run ends.
final class SelfTestLogFile {
    let url: URL
    private var handle: FileHandle?
    private(set) var lineCount = 0

    init?(runId: String, directory: URL? = nil) {
        guard let dir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        url = dir.appendingPathComponent("selftest_\(runId).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
    }

    func write(_ records: [LogRecord]) {
        if handle == nil {
            handle = try? FileHandle(forWritingTo: url)
            do { try handle?.seekToEnd() } catch { close(); return }
        }
        for r in records {
            guard let line = SelfTestLog.line(r), let d = (line + "\n").data(using: .utf8) else { continue }
            do {
                guard let handle else { return }
                try handle.write(contentsOf: d)
                lineCount += 1
            } catch { close(); return }
        }
        close()
    }

    func close() { try? handle?.close(); handle = nil }
}

@MainActor
final class SelfTestRunner: ObservableObject {
    @Published private(set) var state = SelfTestEngine.RunState.idle
    @Published private(set) var results: [StepResult] = []
    @Published private(set) var current: SelfTestStepID?
    @Published private(set) var live = ""
    @Published private(set) var prompt: String?
    @Published private(set) var exportURL: URL?
    @Published private(set) var trackingIncidents = 0
    @Published private(set) var bleDisconnects = 0

    private let link: DriveLink
    private let tracker: PoseTracker
    private var engine = SelfTestEngine()
    private var timer: Timer?
    private var file: SelfTestLogFile?
    private var buffer: [TimedStatus] = []
    private var confirmNext = false
    private var lastWasStop = true
    private var runStartUptime = 0.0
    private var pendingManual: [LogRecord] = []

    init(link: DriveLink, tracker: PoseTracker) {
        self.link = link; self.tracker = tracker
    }

    var isActive: Bool {
        switch state {
        case .running, .awaitingHuman: return true
        default: return false
        }
    }

    func start(checklistConfirmed: Bool) {
        guard !isActive else { return }
        let runId = "run_" + String(UUID().uuidString.prefix(8)).lowercased()
        file = SelfTestLogFile(runId: runId)
        engine = SelfTestEngine()
        results = []; exportURL = nil; prompt = nil; live = ""; buffer = []; confirmNext = false; lastWasStop = true
        link.onStatus = { [weak self] st in
            let t = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                self?.buffer.append(TimedStatus(t: t, uptimeMs: st.uptimeMs, left: st.left, right: st.right,
                                                frontCm: st.frontCm, rearCm: st.rearCm, flags: st.flags.rawValue))
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        runStartUptime = now
        let out = engine.start(now: now, runId: runId, startedUTC: ISO8601DateFormatter().string(from: Date()),
                               checklistConfirmed: checklistConfirmed)
        apply(out)
        if state == .running || isActive {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    /// STOP button: stops the motors first, then tells the engine.
    func stop() {
        link.stop()
        link.setHeartbeatSuspended(false)
        guard isActive else { return }
        apply(engine.abort(.userStop, now: ProcessInfo.processInfo.systemUptime))
    }

    func confirm() { confirmNext = true }

    /// Tape-measured value typed in by the human after a step (the physical truth the ARKit pose cannot give).
    func recordManual(step: SelfTestStepID, key: String, value: Double) {
        guard let file else { return }
        let t = ProcessInfo.processInfo.systemUptime - runStartUptime
        file.write([SelfTestLog.event(t: t, step: step, name: "manual_measurement", ["key": key, "value": value, "source": "human tape measure"])])
    }

    private func tick() {
        guard isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let frameFresh = tracker.session.currentFrame.map { now - $0.timestamp <= 1.0 } ?? false
        let input = SelfTestInput(now: now, pose: frameFresh ? tracker.pose : nil,
                                  tracking: frameFresh ? tracker.tracking : .notAvailable, statuses: buffer,
                                  bleConnected: link.isConnected, guardLevel: guardLevel(), confirm: confirmNext)
        buffer = []; confirmNext = false
        apply(engine.tick(input))
    }

    private func apply(_ out: SelfTestOutput) {
        file?.write(out.records)
        switch out.command {
        case .drive(let l, let r):
            link.setHeartbeatSuspended(false); link.drive(left: l, right: r); lastWasStop = false
        case .stop:
            link.setHeartbeatSuspended(false)
            if !lastWasStop { link.stop(); lastWasStop = true } else { link.drive(left: 0, right: 0) }
        case .silent:
            link.setHeartbeatSuspended(true); lastWasStop = false
        }
        state = out.state
        prompt = out.prompt
        results = engine.results
        current = engine.currentStep
        live = engine.liveReading
        trackingIncidents = engine.trackingIncidents
        bleDisconnects = engine.bleDisconnects
        if out.state.isTerminal { finishRun() }
    }

    private func finishRun() {
        timer?.invalidate(); timer = nil
        link.stop(); link.setHeartbeatSuspended(false)
        link.onStatus = nil
        file?.close()
        exportURL = file?.url
    }

    /// LiDAR corridor + sonar through ObstacleGuard's decision logic. nil when there is no depth frame source.
    private func guardLevel() -> SelfTestGuardLevel? {
        guard let frame = tracker.session.currentFrame,
              ProcessInfo.processInfo.systemUptime - frame.timestamp <= 1.0,
              let corridor = DepthAdapter.corridorResult(from: frame), !corridor.isBlind() else { return nil }
        let sonar = link.robot.map { SonarSample(frontCm: $0.frontCm, rearCm: $0.rearCm, flags: $0.flags.rawValue) }
        switch ObstacleLogic.evaluate(corridor: corridor, sonar: sonar).level {
        case .clear: return .clear
        case .slow: return .slow
        case .stop: return .stop
        }
    }
}
