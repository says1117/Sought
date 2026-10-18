import XCTest
#if canImport(PlannerCore)
@testable import PlannerCore
#endif

/// Remote Teach command text (spec shared with Sought): forward/back <x> m, turn left/right <deg>, scan here,
/// mark <name>, save map, stop.
final class RemoteTeachPlannerTests: XCTestCase {
    private func parse(_ s: String) throws -> [ToolCall] { try KeywordPlanner.parse(s, context: PlannerContext()) }

    func testMoveForwardAndBack() throws {
        XCTAssertEqual(try parse("forward 0.5 m"), [.move(meters: 0.5)])
        XCTAssertEqual(try parse("forward 1 m"), [.move(meters: 1.0)])
        XCTAssertEqual(try parse("Forward 0.3m"), [.move(meters: 0.3)])
        XCTAssertEqual(try parse("back 0.5 m"), [.move(meters: -0.5)])
        XCTAssertEqual(try parse("back 0.25 meters"), [.move(meters: -0.25)])
        XCTAssertEqual(try parse("forward .4 m"), [.move(meters: 0.4)])
    }

    func testMoveDefaultsToHalfAMetre() throws {
        XCTAssertEqual(try parse("forward"), [.move(meters: 0.5)])
        XCTAssertEqual(try parse("back"), [.move(meters: -0.5)])
        XCTAssertEqual(try parse("forward m"), [.move(meters: 0.5)])
    }

    func testMoveClampsIntoRangeAndRefusesZero() throws {
        XCTAssertEqual(try parse("forward 3 m"), [.move(meters: 1.0)])
        XCTAssertEqual(try parse("back 0.05 m"), [.move(meters: -0.1)])
        XCTAssertThrowsError(try parse("forward 0 m"))
        XCTAssertThrowsError(try parse("forward -1 m"))
    }

    func testTurnLeftAndRight() throws {
        XCTAssertEqual(try parse("turn left 90"), [.turn(degrees: 90)])
        XCTAssertEqual(try parse("turn right 45"), [.turn(degrees: -45)])
        XCTAssertEqual(try parse("turn left 30 degrees"), [.turn(degrees: 30)])
        XCTAssertEqual(try parse("turn right 180°"), [.turn(degrees: -180)])
    }

    func testTurnDefaultsAndRange() throws {
        XCTAssertEqual(try parse("turn left"), [.turn(degrees: 90)])
        XCTAssertEqual(try parse("turn right"), [.turn(degrees: -90)])
        XCTAssertEqual(try parse("turn left 360"), [.turn(degrees: 180)])
        XCTAssertEqual(try parse("turn right 5"), [.turn(degrees: -10)])
        XCTAssertThrowsError(try parse("turn left 0"))
    }

    func testScanSaveMarkStop() throws {
        XCTAssertEqual(try parse("scan here"), [.scanHere])
        XCTAssertEqual(try parse("Scan here."), [.scanHere])
        XCTAssertEqual(try parse("save map"), [.saveMap])
        XCTAssertEqual(try parse("save the map"), [.saveMap])
        XCTAssertEqual(try parse("mark kitchen"), [.markWaypoint(name: "kitchen")])
        XCTAssertEqual(try parse("mark this as front door"), [.markWaypoint(name: "front door")])
        XCTAssertEqual(try parse("stop"), [.stop])
        XCTAssertThrowsError(try parse("mark"))
    }

    func testOtherGrammarUnchanged() throws {
        XCTAssertEqual(try KeywordPlanner.parse("go to the kitchen", context: PlannerContext(waypointNames: ["Kitchen"])),
                       [.goToWaypoint(name: "Kitchen")])
        XCTAssertEqual(try parse("find my keys"), [.findObject(description: "keys")])
        XCTAssertEqual(try parse("explore"), [.explore(maxMinutes: nil)])
    }

    func testModelArgumentsAreRangeChecked() throws {
        XCTAssertEqual(try ToolCall.parse(name: "move", args: ["meters": NSNumber(value: -0.4)]), .move(meters: -0.4))
        XCTAssertEqual(try ToolCall.parse(name: "move", args: ["meters": NSNumber(value: 5)]), .move(meters: 1.0))
        XCTAssertEqual(try ToolCall.parse(name: "turn", args: ["degrees": NSNumber(value: -400)]), .turn(degrees: -180))
        XCTAssertEqual(try ToolCall.parse(name: "scan_here", args: [:]), .scanHere)
        XCTAssertEqual(try ToolCall.parse(name: "save_map", args: [:]), .saveMap)
        XCTAssertThrowsError(try ToolCall.parse(name: "move", args: ["meters": NSNumber(value: 0)]))
        XCTAssertThrowsError(try ToolCall.parse(name: "move", args: ["meters": "far"]))
        XCTAssertThrowsError(try ToolCall.parse(name: "turn", args: ["degrees": kCFBooleanTrue as Any]))
        XCTAssertThrowsError(try ToolCall.parse(name: "move", args: [:]))
    }

    func testAckNumberText() {
        XCTAssertEqual(RemoteTeachText.meters(0.5), "0.5")
        XCTAssertEqual(RemoteTeachText.meters(1.0), "1")
        XCTAssertEqual(RemoteTeachText.meters(0.25), "0.25")
        XCTAssertEqual(RemoteTeachText.degrees(90), "90")
    }
}
