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

final class DrivePadTests: XCTestCase {
    private let uart = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"

    func testNoHeldButtonStops() {
        // A cancelled gesture resets the held state to nil: must be STOP, not the last speed.
        XCTAssertEqual(DrivePad.action(held: nil, speed: 150), .stop)
    }

    func testZeroSpeedStops() {
        XCTAssertEqual(DrivePad.action(held: .forward, speed: 0), .stop)
    }

    func testDisabledPadStopsEvenWithHeldButton() {
        XCTAssertEqual(DrivePad.action(held: .forward, speed: 150, isEnabled: false), .stop)
    }

    func testExtremeNegativeSpeedDoesNotOverflow() {
        XCTAssertEqual(DrivePad.action(held: .forward, speed: Int.min), .drive(left: 255, right: 255))
    }

    func testIntentsMapToWheels() {
        XCTAssertEqual(DrivePad.action(held: .forward, speed: 150), .drive(left: 150, right: 150))
        XCTAssertEqual(DrivePad.action(held: .back, speed: 150), .drive(left: -150, right: -150))
        XCTAssertEqual(DrivePad.action(held: .left, speed: 150), .drive(left: -150, right: 150))
        XCTAssertEqual(DrivePad.action(held: .right, speed: 150), .drive(left: 150, right: -150))
        XCTAssertEqual(DrivePad.action(held: .forward, speed: 999), .drive(left: 255, right: 255))
    }

    func testMatchRequiresNameAndService() {
        XCTAssertTrue(PeripheralMatch.isNavigator(advertisedName: "Navigator", cachedName: nil, advertisedServiceUUIDs: [uart]))
        XCTAssertTrue(PeripheralMatch.isNavigator(advertisedName: nil, cachedName: "Navigator", advertisedServiceUUIDs: [uart.lowercased()]))
        XCTAssertFalse(PeripheralMatch.isNavigator(advertisedName: "OtherTeamRover", cachedName: nil, advertisedServiceUUIDs: [uart]))
        XCTAssertFalse(PeripheralMatch.isNavigator(advertisedName: nil, cachedName: nil, advertisedServiceUUIDs: [uart]))
        XCTAssertFalse(PeripheralMatch.isNavigator(advertisedName: "Navigator", cachedName: nil, advertisedServiceUUIDs: []))
        XCTAssertFalse(PeripheralMatch.isNavigator(advertisedName: "Navigator", cachedName: nil, advertisedServiceUUIDs: ["180F"]))
    }
}

final class DriveLinkSessionTests: XCTestCase {
    func testCommandsBeforeReadinessAreDiscarded() {
        var session = DriveLinkSession()
        session.drive(left: 150, right: 150)
        XCTAssertFalse(session.isReady)
        session.connect()
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.left, 0)
        XCTAssertEqual(session.right, 0)
    }

    func testResetClearsMotionAndRejectsCommandsUntilReconnect() {
        var session = DriveLinkSession()
        session.connect()
        session.drive(left: 150, right: -150)
        session.reset()
        session.drive(left: 200, right: 200)
        XCTAssertFalse(session.isReady)
        XCTAssertEqual(session.left, 0)
        XCTAssertEqual(session.right, 0)
        session.connect()
        XCTAssertEqual(session.left, 0)
        XCTAssertEqual(session.right, 0)
    }

    func testReadyCommandsClampAndStopZerosBothWheels() {
        var session = DriveLinkSession()
        session.connect()
        session.drive(left: 999, right: -999)
        XCTAssertEqual(session.left, 255)
        XCTAssertEqual(session.right, -255)
        session.stop()
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.left, 0)
        XCTAssertEqual(session.right, 0)
    }
}
