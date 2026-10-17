import XCTest
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(PlannerCore)
@testable import PlannerCore
#endif

final class RobotCoordinatorTests: XCTestCase {
    func testStateSequenceForSuccessfulFind() async throws {
        let r = CoordRig()
        let t = await r.launch(.findObject(description: "blue backpack"))
        XCTAssertEqual(r.coordinator.status, CoordinatorStatus(state: .finding, task: "find: blue backpack"))
        r.finder.finish(.completed(summary: "arrived"))
        try await t.value
        XCTAssertEqual(r.states.seen, [CoordinatorStatus(state: .finding, task: "find: blue backpack"), .idle])
        XCTAssertEqual(r.coordinator.status.state.heartbeatValue, "idle")
        XCTAssertEqual(r.drive.stops, 1)
        XCTAssertEqual(r.coordinator.trace.map(\.event), ["request", "start", "done"])
    }

    func testOneTaskAtATimeSecondIsQueuedAndRunsAfter() async throws {
        let r = CoordRig()
        let first = await r.launch(.explore(maxMinutes: nil))
        let second = await r.launch(.findObject(description: "keys"))
        try await second.value                       // queued: returns right away
        XCTAssertTrue(r.coordinator.hasPending)
        XCTAssertEqual(r.finder.started, [])         // not started while exploring
        XCTAssertEqual(r.coordinator.status.state, .exploring)
        r.explorer.finish(.completed(summary: nil))
        try await first.value
        await coordSettle()
        XCTAssertEqual(r.finder.started, ["find:keys"])
        XCTAssertEqual(r.coordinator.status, CoordinatorStatus(state: .finding, task: "find: keys"))
        r.finder.finish(.completed(summary: nil))
        await coordSettle()
        XCTAssertEqual(r.coordinator.status, .idle)
        XCTAssertFalse(r.coordinator.hasPending)
    }

    func testThirdRequestIsRefusedWithSpokenReason() async throws {
        let r = CoordRig()
        await r.launch(.explore(maxMinutes: nil))
        try await r.launch(.findObject(description: "keys")).value
        try await r.launch(.comeToMe).value
        XCTAssertEqual(r.comer.started, [])
        XCTAssertTrue(r.speaker.said.last?.contains("Say stop first") == true)
        XCTAssertTrue(r.coordinator.trace.contains { $0.event == "refused" })
    }

    func testStopDuringEachTaskType() async throws {
        let calls: [(ToolCall, (CoordRig) -> CoordTestRunner)] = [
            (.explore(maxMinutes: 5), { $0.explorer }),
            (.findObject(description: "mug"), { $0.finder }),
            (.goToWaypoint(name: "kitchen"), { $0.navigator }),
            (.comeToMe, { $0.comer }),
        ]
        for (call, runner) in calls {
            let r = CoordRig()
            let t = await r.launch(call)
            XCTAssertTrue(runner(r).isRunning, call.toolName)
            r.coordinator.stopAll()                  // synchronous
            XCTAssertEqual(r.drive.stops, 1, call.toolName)
            XCTAssertEqual(runner(r).cancels, 1, call.toolName)
            XCTAssertEqual(r.coordinator.status, .idle, call.toolName)
            try await t.value
            XCTAssertFalse(r.coordinator.isBusy)
            XCTAssertEqual(r.coordinator.status, .idle)
        }
    }

    func testStopToolCallAndStopWithNothingRunning() async throws {
        let r = CoordRig()
        try await r.coordinator.execute(.stop)
        r.coordinator.stopAll()
        XCTAssertEqual(r.drive.stops, 2)
        XCTAssertEqual(r.coordinator.status, .idle)
    }

    func testStopDropsPendingAndNewTaskCanStart() async throws {
        let r = CoordRig()
        let first = await r.launch(.explore(maxMinutes: nil))
        try await r.launch(.findObject(description: "keys")).value
        r.coordinator.stopAll()
        try await first.value
        await coordSettle()
        XCTAssertFalse(r.coordinator.hasPending)
        XCTAssertEqual(r.finder.started, [])
        await r.launch(.comeToMe)
        XCTAssertEqual(r.coordinator.status.state, .comingToUser)
    }

    func testTrackingLossLongerThanOneSecondCancelsAndNeedsRescan() async throws {
        let r = CoordRig()
        let t = await r.launch(.goToWaypoint(name: "kitchen"))
        r.pose.value = .limited
        await r.clock.advance(by: 0.8)
        XCTAssertEqual(r.coordinator.status.state, .finding, "still within 1 s")
        XCTAssertEqual(r.drive.stops, 0)
        await r.clock.advance(by: 0.5)
        XCTAssertEqual(r.coordinator.status, CoordinatorStatus(state: .blocked, task: "need a rescan"))
        XCTAssertEqual(r.drive.stops, 1)
        XCTAssertEqual(r.navigator.cancels, 1)
        XCTAssertTrue(r.speaker.said.last?.contains("rescan") == true)
        try await t.value
    }

    func testBriefTrackingDipDoesNotCancel() async throws {
        let r = CoordRig()
        let t = await r.launch(.explore(maxMinutes: nil))
        r.pose.value = .limited
        await r.clock.advance(by: 0.6)
        r.pose.value = .normal
        await r.clock.advance(by: 1.5)
        r.pose.value = .notAvailable
        await r.clock.advance(by: 0.6)
        r.pose.value = .normal
        await r.clock.advance(by: 1.0)
        XCTAssertEqual(r.coordinator.status.state, .exploring)
        XCTAssertEqual(r.drive.stops, 0)
        r.explorer.finish(.completed(summary: nil))
        try await t.value
    }

    func testTrackingLossDropsPendingTask() async throws {
        let r = CoordRig()
        let t = await r.launch(.explore(maxMinutes: nil))
        try await r.launch(.findObject(description: "keys")).value
        r.pose.value = .notAvailable
        await r.clock.advance(by: 1.5)
        try await t.value
        XCTAssertFalse(r.coordinator.hasPending)
        XCTAssertEqual(r.finder.started, [])
    }

    func testTaskDoesNotStartWithoutTracking() async throws {
        let r = CoordRig()
        r.pose.value = .limited
        try await r.coordinator.execute(.findObject(description: "keys"))
        XCTAssertEqual(r.finder.started, [])
        XCTAssertEqual(r.coordinator.status, CoordinatorStatus(state: .blocked, task: "need a rescan"))
    }

    func testUnknownWaypointRejectedWithSpokenReply() async throws {
        let r = CoordRig()
        try await r.coordinator.execute(.goToWaypoint(name: "garage"))
        XCTAssertEqual(r.navigator.started, [])
        XCTAssertEqual(r.coordinator.status, .idle)
        XCTAssertEqual(r.speaker.said, ["I don't know a place called garage."])
        XCTAssertTrue(r.coordinator.trace.contains { $0.event == "rejected" })
    }

    func testUnknownWaypointDoesNotDisturbRunningTask() async throws {
        let r = CoordRig()
        let t = await r.launch(.explore(maxMinutes: nil))
        try await r.coordinator.execute(.goToWaypoint(name: "garage"))
        XCTAssertEqual(r.coordinator.status.state, .exploring)
        XCTAssertFalse(r.coordinator.hasPending)
        r.explorer.finish(.completed(summary: nil))
        try await t.value
    }

    func testSubTaskReportedFailureSurfacesAsBlocked() async throws {
        let r = CoordRig()
        let t = await r.launch(.goToWaypoint(name: "kitchen"))
        r.navigator.finish(.blocked(reason: "path blocked"))
        try await t.value
        XCTAssertEqual(r.coordinator.status, CoordinatorStatus(state: .blocked, task: "path blocked"))
        XCTAssertTrue(r.speaker.said.last?.contains("path blocked") == true)
        // Next request starts normally from blocked.
        await r.launch(.comeToMe)
        XCTAssertEqual(r.coordinator.status.state, .comingToUser)
    }

    func testSubTaskThrowSurfacesAsErrorAndRethrows() async throws {
        let r = CoordRig()
        let t = await r.launch(.explore(maxMinutes: nil))
        r.explorer.fail(CoordTestFailure())
        do { try await t.value; XCTFail("expected throw") } catch { XCTAssertTrue(error is CoordTestFailure) }
        XCTAssertEqual(r.coordinator.status.state, .error)
        XCTAssertFalse(r.coordinator.isBusy)
    }

    func testSayRunsWithoutOccupyingTheSlot() async throws {
        let r = CoordRig()
        let t = await r.launch(.explore(maxMinutes: nil))
        try await r.coordinator.execute(.say(text: "hello"))
        XCTAssertEqual(r.speaker.said, ["hello"])
        XCTAssertEqual(r.coordinator.status.state, .exploring)
        r.explorer.finish(.completed(summary: nil))
        try await t.value
    }

    func testMarkWaypointWhenIdleAndRefusedWhileMoving() async throws {
        let r = CoordRig()
        try await r.coordinator.execute(.markWaypoint(name: "desk"))
        XCTAssertEqual(r.waypoints.marked, ["desk"])
        let t = await r.launch(.explore(maxMinutes: nil))
        try await r.coordinator.execute(.markWaypoint(name: "sofa"))
        XCTAssertEqual(r.waypoints.marked, ["desk"])
        XCTAssertEqual(r.coordinator.status.state, .exploring)
        r.explorer.finish(.completed(summary: nil))
        try await t.value
    }

    func testMarkWaypointNeedsTracking() async throws {
        let r = CoordRig()
        r.pose.value = .limited
        try await r.coordinator.execute(.markWaypoint(name: "desk"))
        XCTAssertEqual(r.waypoints.marked, [])
        XCTAssertTrue(r.speaker.said.last?.contains("rescan") == true)
    }

    func testUnsupportedToolsAreSpokenNotRun() async throws {
        let r = CoordRig()
        try await r.coordinator.execute(.startPatrol)
        XCTAssertEqual(r.coordinator.status, .idle)
        XCTAssertEqual(r.speaker.said, ["I can't do that yet."])
    }

    func testHeartbeatValuesMatchContract() {
        XCTAssertEqual(CoordinatorState.comingToUser.heartbeatValue, "coming_to_user")
        XCTAssertEqual(CoordinatorState.exploring.heartbeatValue, "exploring")
    }
    func testStopFromStartCallbackPreventsRunnerInvocation() async throws {
        let r = CoordRig()
        r.explorer.onStart = { _ in r.explorer.finish(.completed(summary: nil)) }
        r.coordinator.onChange = { status in
            if status.state == .exploring { r.coordinator.stopAll() }
        }
        try await r.coordinator.execute(.explore(maxMinutes: nil))
        XCTAssertEqual(r.explorer.started, [])
        XCTAssertEqual(r.coordinator.status, .idle)
        XCTAssertFalse(r.coordinator.isBusy)
        XCTAssertEqual(r.drive.stops, 1)
    }

    func testStopFromCompletionCallbackCannotResurrectPending() async throws {
        let r = CoordRig()
        let first = await r.launch(.explore(maxMinutes: nil))
        try await r.coordinator.execute(.findObject(description: "keys"))
        r.coordinator.onChange = { status in
            if status == .idle { r.coordinator.stopAll() }
        }
        r.explorer.finish(.completed(summary: nil))
        try await first.value
        await coordSettle()
        XCTAssertEqual(r.finder.started, [])
        XCTAssertFalse(r.coordinator.hasPending)
        XCTAssertEqual(r.coordinator.status, .idle)
    }

    func testStopRetainsOwnershipUntilUncooperativeRunnerReturns() async throws {
        let r = CoordRig()
        r.explorer.finishOnCancel = false
        let first = await r.launch(.explore(maxMinutes: nil))
        r.coordinator.stopAll()
        XCTAssertEqual(r.coordinator.status, .idle)
        XCTAssertTrue(r.coordinator.isBusy, "cancel is a request, not proof of termination")
        try await r.coordinator.execute(.comeToMe)
        XCTAssertEqual(r.comer.started, [])
        XCTAssertFalse(r.coordinator.hasPending)
        r.explorer.finish(.completed(summary: "late success"))
        try await first.value
        XCTAssertEqual(r.coordinator.status, .idle)
        XCTAssertFalse(r.coordinator.isBusy)
        let next = await r.launch(.comeToMe)
        XCTAssertEqual(r.comer.started, ["come"])
        r.comer.finish(.completed(summary: nil))
        try await next.value
    }

    func testCallerCancellationBrakesAndCancelsOwnedRunner() async throws {
        let r = CoordRig()
        let first = await r.launch(.findObject(description: "keys"))
        try await r.coordinator.execute(.comeToMe)
        first.cancel()
        try await first.value
        XCTAssertEqual(r.drive.stops, 1)
        XCTAssertEqual(r.finder.cancels, 1)
        XCTAssertEqual(r.comer.started, [])
        XCTAssertEqual(r.coordinator.status, .idle)
        XCTAssertFalse(r.coordinator.hasPending)
    }

    func testReportedFailureBrakesAndDropsPending() async throws {
        let r = CoordRig()
        let first = await r.launch(.explore(maxMinutes: nil))
        try await r.coordinator.execute(.findObject(description: "keys"))
        r.explorer.finish(.blocked(reason: "guard stopped"))
        try await first.value
        await coordSettle()
        XCTAssertEqual(r.drive.stops, 1)
        XCTAssertEqual(r.finder.started, [])
        XCTAssertFalse(r.coordinator.hasPending)
        XCTAssertEqual(r.coordinator.status.state, .blocked)
    }

    func testThrownFailureBrakesAndDropsPending() async throws {
        let r = CoordRig()
        let first = await r.launch(.explore(maxMinutes: nil))
        try await r.coordinator.execute(.findObject(description: "keys"))
        r.explorer.fail(CoordTestFailure())
        do { try await first.value; XCTFail("expected throw") } catch { XCTAssertTrue(error is CoordTestFailure) }
        await coordSettle()
        XCTAssertEqual(r.drive.stops, 1)
        XCTAssertEqual(r.finder.started, [])
        XCTAssertFalse(r.coordinator.hasPending)
        XCTAssertEqual(r.coordinator.status.state, .error)
    }

}
