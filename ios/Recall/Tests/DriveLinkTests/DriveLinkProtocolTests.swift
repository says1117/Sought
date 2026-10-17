import XCTest
#if canImport(DriveLinkCore)
@testable import DriveLinkCore
#endif

final class DriveLinkProtocolTests: XCTestCase {
    func testDriveCommandFormat() {
        XCTAssertEqual(DriveProtocol.driveCommand(left: 150, right: -150), "150,-150\n")
        XCTAssertEqual(DriveProtocol.driveCommand(left: 0, right: 0), "0,0\n")
    }

    func testDriveCommandClamps() {
        XCTAssertEqual(DriveProtocol.driveCommand(left: 999, right: -999), "255,-255\n")
    }

    func testFixedCommands() {
        XCTAssertEqual(DriveProtocol.stopCommand, "STOP\n")
        XCTAssertEqual(DriveProtocol.pingCommand, "PING\n")
        XCTAssertLessThanOrEqual(DriveProtocol.heartbeatInterval, 0.1)
    }

    func testMixTurnConvention() {
        // angular > 0 turns left: right wheel faster than left
        let m = DriveProtocol.mix(linear: 100, angular: 40)
        XCTAssertEqual(m.left, 60)
        XCTAssertEqual(m.right, 140)
        let clamped = DriveProtocol.mix(linear: 250, angular: 50)
        XCTAssertEqual(clamped.left, 200)
        XCTAssertEqual(clamped.right, 255)
    }

    func testParseStatus() {
        let s = RobotStatus.parse("T,12345,100,-100,42,999,10\n")
        XCTAssertEqual(s, RobotStatus(uptimeMs: 12345, left: 100, right: -100, frontCm: 42, rearCm: 999,
                                      flags: [.frontBlocked, .bleConnected]))
        XCTAssertEqual(s?.frontDistanceCm, 42)
        XCTAssertNil(s?.rearDistanceCm)
    }

    func testFlagBits() {
        let s = RobotStatus.parse("T,1,0,0,10,10,15")
        XCTAssertEqual(s?.flags, [.watchdogStopped, .frontBlocked, .rearBlocked, .bleConnected])
    }

    func testParseRejectsBadLines() {
        for bad in ["", "PONG", "T,1,2,3", "T,1,2,3,4,5,6,7", "X,1,2,3,4,5,6", "T,a,0,0,1,1,0", "T,1,0,0,,1,0", "T,1,0,0,-5,1,0"] {
            XCTAssertNil(RobotStatus.parse(bad), bad)
        }
    }

    func testLineBufferHandlesSplitPackets() {
        var b = LineBuffer()
        XCTAssertEqual(b.append("T,1,0,0,5"), [])
        XCTAssertEqual(b.append("0,50,8\nPONG\nT,2"), ["T,1,0,0,50,50,8", "PONG"])
        XCTAssertEqual(b.append(",0,0,1,1,0\n"), ["T,2,0,0,1,1,0"])
    }
}
