import XCTest
@testable import Companion

@MainActor
final class CompanionModelTests: XCTestCase {
    private final class Link: HandheldPeerTransport {
        var onMessage: ((CompanionMessage) -> Void)?
        var onConnection: ((Bool, String?) -> Void)?
        var sent: [CompanionMessage] = []
        var events: [String] = []
        var starts = 0
        var delivers = true
        func start() { starts += 1; events.append("start") }
        func stop() { events.append("stop") }
        func send(_ message: CompanionMessage) -> Bool {
            sent.append(message)
            if case .cancel = message { events.append("cancel") }
            return delivers
        }
    }
    private final class Ranging: HandheldRanging {
        var onUpdate: (() -> Void)?
        var onInvalidated: ((Error) -> Void)?
        var sample = RangeSample()
        func latest() -> RangeSample { sample }
        func prepare() -> String? { "local-token" }
        func run(peerTokenB64: String, cameraAssistance: Bool) -> Bool { !cameraAssistance }
        func stop() { sample = RangeSample() }
    }
    private func ready(_ model: CompanionModel, _ link: Link, _ ranging: Ranging) {
        model.pairingCode = "123456"
        model.start()
        link.onConnection?(true, "Robot")
        link.onMessage?(.hello(role: .robot, version: CompanionMessage.protocolVersion))
        link.onMessage?(.niToken(tokenB64: "peer-token"))
        ranging.sample = RangeSample(distanceM: 2, bearingDeg: 10, updatedAt: 10)
        ranging.onUpdate?()
    }
    private func requestedId(_ link: Link) -> String? {
        for message in link.sent.reversed() { if case .comeToMe(let id) = message { return id } }
        return nil
    }

    func testPairingCodeRequiresSixASCIIDigits() {
        for code in [nil, "", "12345", "1234567", "12a456", "１２３４５６", " 12345"] {
            XCTAssertNil(CompanionLink.validPairingCode(code))
        }
        XCTAssertEqual(CompanionLink.validPairingCode("000123"), "000123")
    }

    func testUnsupportedOrUnpairedDeviceNeverSendsCome() {
        let link = Link(), range = Ranging()
        let model = CompanionModel(link: link, ranging: range, supportsGuidance: false, clock: { 10 })
        model.pairingCode = "123456"; model.start(); model.comeToMe()
        XCTAssertEqual(link.starts, 0)
        XCTAssertNil(requestedId(link))
        XCTAssertFalse(model.canRequest)
        model.shutdown()
    }

    func testReadinessRequiresFreshFiniteDistanceAndBearing() {
        let good = RangeSample(distanceM: 2, bearingDeg: 0, updatedAt: 10)
        XCTAssertTrue(CompanionModel.fresh(good, now: 11))
        XCTAssertFalse(CompanionModel.fresh(good, now: 12.1))
        XCTAssertFalse(CompanionModel.fresh(good, now: 9))
        for bad in [RangeSample(distanceM: .nan, bearingDeg: 0, updatedAt: 10),
                    RangeSample(distanceM: 0, bearingDeg: 0, updatedAt: 10),
                    RangeSample(distanceM: 2, bearingDeg: nil, updatedAt: 10),
                    RangeSample(distanceM: 2, bearingDeg: .infinity, updatedAt: 10),
                    RangeSample(distanceM: 2, bearingDeg: 0, updatedAt: nil)] {
            XCTAssertFalse(CompanionModel.fresh(bad, now: 10))
        }
    }

    func testRobotHelloAndRangingRequiredBeforeRequest() {
        let link = Link(), range = Ranging()
        let model = CompanionModel(link: link, ranging: range, supportsGuidance: true, clock: { 10 })
        model.pairingCode = "123456"; model.start(); link.onConnection?(true, "Robot")
        range.sample = RangeSample(distanceM: 2, bearingDeg: 0, updatedAt: 10)
        range.onUpdate?()
        model.comeToMe()
        XCTAssertNil(requestedId(link))
        link.onMessage?(.hello(role: .robot, version: CompanionMessage.protocolVersion))
        XCTAssertFalse(model.canRequest)
        link.onMessage?(.niToken(tokenB64: "peer-token"))
        model.comeToMe()
        XCTAssertNotNil(requestedId(link))
        XCTAssertFalse(model.canRequest, "one active request only")
        model.shutdown()
    }

    func testFailedStopRetainsRetryAndNeverClaimsStopped() throws {
        let link = Link(), range = Ranging()
        let model = CompanionModel(link: link, ranging: range, supportsGuidance: true, clock: { 10 })
        ready(model, link, range); model.comeToMe()
        let id = try XCTUnwrap(requestedId(link))
        link.delivers = false; model.cancel()
        XCTAssertTrue(model.canCancel)
        XCTAssertFalse(model.canRequest)
        guard case .lostContact = model.phase else { return XCTFail("Stop was not confirmed") }
        link.delivers = true; model.cancel()
        XCTAssertEqual(model.phase, .stopping)
        link.onMessage?(.status(id: id, state: .approaching, distanceM: 2, reason: nil))
        XCTAssertEqual(model.phase, .stopping)
        link.onMessage?(.status(id: id, state: .failed, distanceM: nil, reason: "cancelled"))
        XCTAssertFalse(model.canCancel)
        XCTAssertTrue(model.canRequest)
        model.shutdown()
    }

    func testTerminalStatusCannotBeReopenedByLateAcceptedMessage() throws {
        let link = Link(), range = Ranging()
        let model = CompanionModel(link: link, ranging: range, supportsGuidance: true, clock: { 10 })
        ready(model, link, range); model.comeToMe()
        let id = try XCTUnwrap(requestedId(link))
        link.onMessage?(.status(id: id, state: .approaching, distanceM: 2, reason: nil))
        link.onMessage?(.status(id: id, state: .accepted, distanceM: nil, reason: nil))
        XCTAssertEqual(model.phase, .approaching)
        link.onMessage?(.status(id: id, state: .arrived, distanceM: 1, reason: nil))
        link.onMessage?(.status(id: id, state: .accepted, distanceM: nil, reason: nil))
        XCTAssertEqual(model.phase, .arrived)
        model.shutdown()
    }

    func testShutdownSendsCancelBeforeTransportTeardownAndOldCallbackCannotAffectNewPair() {
        let link = Link(), range = Ranging()
        let model = CompanionModel(link: link, ranging: range, supportsGuidance: true, clock: { 10 })
        ready(model, link, range); model.comeToMe()
        let oldConnection = link.onConnection
        link.events = []
        model.shutdown()
        XCTAssertEqual(link.events.prefix(2), ["cancel", "stop"])
        XCTAssertFalse(model.canRequest)
        model.start(); link.onConnection?(true, "New robot")
        oldConnection?(false, nil)
        XCTAssertEqual(model.peerName, "New robot")
        model.shutdown()
    }

    func testLostPeerRequiresNewPairAndConfirmationOfOutstandingStop() throws {
        let link = Link(), range = Ranging()
        let model = CompanionModel(link: link, ranging: range, supportsGuidance: true, clock: { 10 })
        ready(model, link, range); model.comeToMe()
        let id = try XCTUnwrap(requestedId(link))
        link.onConnection?(false, nil)
        XCTAssertTrue(model.canCancel)
        XCTAssertFalse(model.canRequest)
        ready(model, link, range)
        XCTAssertEqual(model.phase, .stopping)
        XCTAssertTrue(link.sent.contains(.cancel(id: id)))
        XCTAssertFalse(model.canRequest)
        link.onMessage?(.status(id: id, state: .failed, distanceM: nil, reason: "cancelled"))
        XCTAssertTrue(model.canRequest)
        model.shutdown()
    }

    func testCodeChangeDuringCommandCancelsAndDisconnects() {
        let link = Link(), range = Ranging()
        let model = CompanionModel(link: link, ranging: range, supportsGuidance: true, clock: { 10 })
        ready(model, link, range); model.comeToMe()
        link.events = []
        model.pairingCode = "654321"
        XCTAssertEqual(link.events.prefix(2), ["cancel", "stop"])
        XCTAssertFalse(model.canRequest)
        model.shutdown()
    }

    func testBearingPreservesSideAndBehindAnglesAndRejectsVerticalOrInvalidVectors() {
        XCTAssertEqual(NIRanging.horizontalBearing(x: -1, y: 0, z: -1) ?? .nan, 45, accuracy: 1e-9)
        XCTAssertEqual(NIRanging.horizontalBearing(x: 1, y: 0, z: -1) ?? .nan, -45, accuracy: 1e-9)
        XCTAssertEqual(NIRanging.horizontalBearing(x: 1, y: 0, z: 1) ?? .nan, -135, accuracy: 1e-9)
        XCTAssertNil(NIRanging.horizontalBearing(x: 0, y: 1, z: 0))
        XCTAssertNil(NIRanging.horizontalBearing(x: .nan, y: 0, z: -1))
    }
}
