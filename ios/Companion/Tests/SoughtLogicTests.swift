import XCTest
@testable import Companion

// Pure logic behind what Sought says: status copy, the activity log, search matching, pin naming, backend decoding.

@MainActor
final class SoughtLogicTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(_ s: RobotState, battery: Double? = 0.82, ago: TimeInterval = 1, task: String? = nil) -> RobotStatus {
        RobotStatus(state: s, task: task, battery: battery, pose: nil, lastHeartbeat: now.addingTimeInterval(-ago))
    }

    private func item(_ id: String, _ label: String, x: Double = 0, z: Double = 0, history: [HistoryPoint] = [],
                      firstSeenAgo: TimeInterval = 86_400) -> TrackedObject {
        TrackedObject(id: id, label: label, description: nil, x: x, z: z, firstSeen: now.addingTimeInterval(-firstSeenAgo),
                      lastSeen: now, sightings: 2, history: history, whereText: "By the door", room: "Hallway", photo: .none)
    }

    // MARK: Status copy

    func testStatusLinesUsePlainWordsAndBattery() {
        XCTAssertEqual(StatusCopy.line(status(.exploring), now: now), "Soughtbot is roaming · 82%")
        XCTAssertEqual(StatusCopy.line(status(.idle, battery: nil), now: now), "Soughtbot is resting")
        XCTAssertEqual(StatusCopy.line(status(.finding, task: "find: blue backpack"), now: now), "Soughtbot is looking for blue backpack · 82%")
        XCTAssertEqual(StatusCopy.line(status(.blocked, battery: nil), now: now), "Soughtbot is stuck. Something is in the way")
    }

    func testOfflineAfterTenSecondsWithoutHeartbeat() {
        XCTAssertEqual(StatusCopy.line(status(.exploring, ago: 240), now: now), "Soughtbot is offline · last seen 4 min ago")
        XCTAssertEqual(StatusCopy.line(RobotStatus(state: .idle, task: nil, battery: nil, pose: nil, lastHeartbeat: nil), now: now),
                       "Soughtbot is offline")
    }

    func testSpokenStatusHasNoSymbols() {
        XCTAssertEqual(StatusCopy.spoken(status(.exploring), now: now), "Soughtbot is roaming. 82 percent battery")
    }

    func testNoEmDashesInStatusCopy() {
        for s in RobotState.allCases {
            XCTAssertFalse(StatusCopy.line(status(s), now: now).contains("\u{2014}"), "em dash in \(s)")
        }
    }

    // MARK: Activity log

    func testMoveOverThresholdIsAnEventAndSmallJitterIsNot() {
        let moved = item("a", "slippers", history: [HistoryPoint(t: now.addingTimeInterval(-7200), x: 0, z: 0),
                                                   HistoryPoint(t: now.addingTimeInterval(-60), x: 2, z: 0)])
        let jitter = item("b", "lamp", history: [HistoryPoint(t: now.addingTimeInterval(-7200), x: 0, z: 0),
                                                HistoryPoint(t: now.addingTimeInterval(-60), x: 0.5, z: 0)])
        let events = ActivityDeriver.events(objects: [moved, jitter], map: nil, finds: [], robotLog: [], now: now)
        XCTAssertEqual(events.map(\.kind), [.moved])
        XCTAssertEqual(events.first?.text, "Slippers moved by the door")
    }

    func testNewItemsOnlyInsideSixHours() {
        let fresh = item("n", "Lamp", firstSeenAgo: 3600)
        let old = item("o", "Sofa", firstSeenAgo: 86_400)
        let events = ActivityDeriver.events(objects: [fresh, old], map: nil, finds: [], robotLog: [], now: now)
        XCTAssertEqual(events.map(\.id), ["new-n"])
        XCTAssertEqual(events.first?.text, "Soughtbot noticed a lamp in the hallway")
    }

    func testFindsAndRobotEventsAreNewestFirst() {
        let finds = [FindRecord(query: "car keys", objectId: nil, found: false, at: now.addingTimeInterval(-600)),
                     FindRecord(query: "umbrella", objectId: nil, found: true, at: now.addingTimeInterval(-60))]
        let log = [RobotLogEntry(text: "Soughtbot got stuck by the sofa", at: now.addingTimeInterval(-300))]
        let events = ActivityDeriver.events(objects: [], map: nil, finds: finds, robotLog: log, now: now)
        XCTAssertEqual(events.map(\.kind), [.found, .robot, .notFound])
        XCTAssertEqual(events.last?.text, "Couldn\u{2019}t find your car keys")
        XCTAssertEqual(activityPill(events[0], now: now), "Found · 1 min ago")
    }

    // MARK: Search matching

    func testBestMatchUsesWordsAndPlurals() {
        let source = RobotSource()
        source.objects = [item("1", "Red Umbrella"), item("2", "Brown Sandals"), item("3", "Router")]
        XCTAssertEqual(source.bestMatch(for: "where is my umbrella")?.id, "1")
        XCTAssertEqual(source.bestMatch(for: "sandal")?.id, "2")
        XCTAssertNil(source.bestMatch(for: "car keys"))
        XCTAssertNil(source.bestMatch(for: "find my"))
    }

    func testPinsAreSearchableAndNeverCountAsFinds() {
        let source = RobotSource()
        source.objects = [item("1", "Router")]
        source.pins = [UserPin(id: "pin_1", label: "TV remote", note: nil, x: 0, z: 0, place: "On the sofa", room: nil,
                               createdAt: now, photo: nil)]
        XCTAssertEqual(source.bestMatch(for: "remote")?.id, "pin_1")
        XCTAssertTrue(source.bestMatch(for: "remote")?.isPin ?? false)
        XCTAssertEqual(source.recentFinds.map(\.id), ["1"])
        XCTAssertEqual(source.items.count, 2)
        XCTAssertEqual(source.items.last?.certaintyWord, "Pinned by you")
    }

    // MARK: Naming what the robot found (no labeler on the robot yet)

    func testUnnamedItemsReadAsSomethingAndBecomeSearchableOnceNamed() {
        let source = RobotSource()
        var o = item("obj_r1", "Unnamed item", firstSeenAgo: 600)
        o.needsName = true
        o.whereText = "Near the sofa"
        source.objects = [o]
        XCTAssertEqual(source.unnamed.map(\.id), ["obj_r1"])
        let events = ActivityDeriver.events(objects: source.objects, map: nil, finds: [], robotLog: [], now: now)
        XCTAssertEqual(events.first?.text, "Soughtbot noticed something near the sofa")
        XCTAssertNil(source.bestMatch(for: "slippers"))
        source.setName("slippers", for: "obj_r1")
        XCTAssertEqual(source.objects.first?.label, "Slippers")
        XCTAssertFalse(source.objects.first?.needsName ?? true)
        XCTAssertEqual(source.bestMatch(for: "find my slippers")?.id, "obj_r1")
        XCTAssertTrue(source.unnamed.isEmpty)
        UserDefaults.standard.removeObject(forKey: "itemNames")
    }

    // MARK: Pins

    func testPinPlaceNamesComeFromTaughtSpotsThenRooms() {
        let map = MapSnapshot(rooms: [Room(name: "Kitchen", minX: 0, minZ: 0, maxX: 4, maxZ: 4)],
                              waypoints: [Waypoint(id: "w", name: "kitchen table", x: 1, z: 1)], grid: nil, trail: [], updatedAt: now)
        XCTAssertEqual(PinStore.placeName(x: 1.3, z: 1.2, map: map).place, "On the kitchen table")
        XCTAssertEqual(PinStore.placeName(x: 3.5, z: 3.5, map: map).place, "In the kitchen")
        XCTAssertEqual(PinStore.placeName(x: 9, z: 9, map: map).place, "On the map")
    }

    // MARK: Backend decoding (shapes from docs/03_CONTRACTS.md section 2, as served by backend PR 12)

    func testBackendDatesWithAndWithoutFractions() throws {
        struct D: Decodable { var t: Date }
        let a = try BackendRobotSource.decoder.decode(D.self, from: Data(#"{"t":"2026-10-18T02:28:25.169935Z"}"#.utf8))
        let b = try BackendRobotSource.decoder.decode(D.self, from: Data(#"{"t":"2026-10-17T14:03:22Z"}"#.utf8))
        XCTAssertGreaterThan(a.t, b.t)
    }

    func testBackendConfigRejectsPlaceholders() {
        XCTAssertNil(BackendConfig.clean("https://your-host.example.com"))
        XCTAssertNil(BackendConfig.clean("$(BACKEND_BASE_URL)"))
        XCTAssertNotNil(BackendConfig.clean("http://127.0.0.1:8765"))
    }

    // MARK: PR 40 review fixes

    func testComeToMeSendsComeToPlaceNotPlainGoTo() {
        let wps = [Waypoint(id: "w1", name: "kitchen table", x: 1, z: 1)]
        XCTAssertEqual(BackendRobotSource.comeCommand(ComeTarget(waypointId: "w1", name: "the kitchen table", x: 1, z: 1), waypoints: wps),
                       "come to the kitchen table")
        XCTAssertEqual(BackendRobotSource.comeCommand(ComeTarget(waypointId: nil, name: "the sofa", x: 0, z: 0), waypoints: wps),
                       "come to the sofa")
    }

    func testTransportErrorsKeepStopButRobotAnswersDoNot() {
        XCTAssertTrue(BackendRobotSource.isTransportProblem(.network))
        XCTAssertTrue(BackendRobotSource.isTransportProblem(.timeout))
        XCTAssertTrue(BackendRobotSource.isTransportProblem(.http(502)))
        XCTAssertFalse(BackendRobotSource.isTransportProblem(.failed("blocked")))
        XCTAssertFalse(BackendRobotSource.isTransportProblem(.busy))
        XCTAssertFalse(BackendRobotSource.isTransportProblem(.unauthorized))
    }

    func testExpiredHeartbeatRefreshesTheClockAtOnce() {
        let robot = RobotSource()
        robot.now = Date(timeIntervalSinceNow: -3600)   // the 15 s clock has not ticked yet
        robot.status.lastHeartbeat = Date(timeIntervalSinceNow: -20)   // already older than 10 s when it arrives
        XCTAssertGreaterThan(robot.now.timeIntervalSinceNow, -1)
        XCTAssertFalse(robot.status.isOnline(now: robot.now))
        robot.status.lastHeartbeat = Date()
        XCTAssertTrue(robot.status.isOnline(now: robot.now))
    }

    func testTypedPlacePhrasesAreNotWrappedInFind() {
        XCTAssertEqual(BackendRobotSource.findText(query: "Go to the kitchen", match: nil), "Go to the kitchen")
        XCTAssertEqual(BackendRobotSource.findText(query: "come to the sofa", match: nil), "come to the sofa")
        XCTAssertEqual(BackendRobotSource.findText(query: "car keys", match: nil), "find car keys")
    }
}
