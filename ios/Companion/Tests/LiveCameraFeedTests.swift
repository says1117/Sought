import XCTest
import UIKit
@testable import Companion

@MainActor
final class LiveCameraFeedTests: XCTestCase {
    private let config = BackendConfig(baseURL: URL(string: "https://robot.example.org")!, token: "test-camera-token")

    private func jpeg(width: CGFloat = 8, height: CGFloat = 6) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).jpegData(withCompressionQuality: 0.5) { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func response(_ code: Int = 200, age: String? = "0", mime: String = "image/jpeg") -> HTTPURLResponse {
        var headers = ["Content-Type": mime, "Cache-Control": "no-store"]
        if let age { headers["X-Frame-Age-Ms"] = age }
        return HTTPURLResponse(url: config.baseURL.appending(path: "api/camera/frame"), statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    private func until(_ predicate: () -> Bool) async {
        for _ in 0..<100 where !predicate() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate())
    }

    func testAuthenticatesWithoutTokenInURLAndStartsOnlyOnce() async {
        let data = jpeg(); let reply = response(age: "1200")
        var requests: [URLRequest] = []
        var frame: LiveCameraFrame?
        let feed = LiveCameraFeed(config: config, transport: { request in
            requests.append(request); return (data, reply)
        }, clock: { 100 }, interval: 100) { frame = $0; _ = $1 }
        feed.start(); feed.start()
        await until { frame != nil }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/api/camera/frame")
        XCTAssertNil(requests.first?.url?.query)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-camera-token")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(frame?.age(now: 102) ?? -1, 3.2, accuracy: 0.0001)
        feed.stop()
        XCTAssertNil(frame)
    }

    func testNoFrameStaleServerAndInvalidAgeNeverShowImage() async {
        for reply in [response(404), response(410), response(age: "5000"), response(age: nil), response(age: "nan"), response(age: "-1")] {
            var state = LiveCameraState.idle
            var frame: LiveCameraFrame?
            let data = jpeg()
            let feed = LiveCameraFeed(config: config, transport: { _ in (data, reply) }, interval: 100) {
                frame = $0; state = $1
            }
            feed.start()
            await until { state == .unavailable }
            XCTAssertNil(frame)
            feed.stop()
        }
    }

    func testFrameExpiresEvenWhileNextRequestIsNotDue() async {
        let data = jpeg(); let reply = response(age: "4950")
        var state = LiveCameraState.idle
        var frame: LiveCameraFrame?
        let feed = LiveCameraFeed(config: config, transport: { _ in (data, reply) }, clock: { 10 }, interval: 100) {
            frame = $0; state = $1
        }
        feed.start()
        await until { state == .live }
        await until { state == .unavailable }
        XCTAssertNil(frame)
        feed.stop()
    }

    func testTransferTimeCountsAgainstFreshness() async {
        var time = 0.0
        var state = LiveCameraState.idle
        let data = jpeg(); let reply = response(age: "0")
        let feed = LiveCameraFeed(config: config, transport: { _ in time = 6; return (data, reply) }, clock: { time }, interval: 100) {
            XCTAssertNil($0); state = $1
        }
        feed.start()
        await until { state == .unavailable }
        feed.stop()
    }

    func testImageBoundsAndFormatValidatedBeforeDisplay() {
        XCTAssertNotNil(LiveCameraFeed.decode(jpeg(), response: response()))
        XCTAssertNil(LiveCameraFeed.decode(jpeg(width: 641), response: response()))
        XCTAssertNil(LiveCameraFeed.decode(jpeg(height: 641), response: response()))
        XCTAssertNil(LiveCameraFeed.decode(jpeg(), response: response(mime: "image/png")))
        XCTAssertNil(LiveCameraFeed.decode(Data(repeating: 0, count: LiveCameraFeed.maxBytes + 1), response: response()))
        XCTAssertNil(LiveCameraFeed.decode(Data([0xff, 0xd8, 0xff]), response: response()))
    }

    func testClosedAndRestartedFeedIgnoresLateResponseFromOldGeneration() async {
        var held: CheckedContinuation<(Data, URLResponse), Never>?
        var calls = 0
        var displayedAges: [Double] = []
        let data = jpeg(); let reply = response(age: "1000")
        let feed = LiveCameraFeed(config: config, transport: { _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { held = $0 } }
            return (data, reply)
        }, clock: { 0 }, interval: 100) { frame, _ in
            if let frame { displayedAges.append(frame.responseAge) }
        }
        feed.start()
        await until { held != nil }
        feed.stop(); feed.start()
        await until { displayedAges.count == 1 }
        held?.resume(returning: (data, response(age: "0")))
        held = nil
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(displayedAges, [1])
        feed.stop()
    }

    func testNetworkFailureClearsPreviousFrame() async {
        let data = jpeg(); let reply = response()
        var calls = 0
        var state = LiveCameraState.idle
        var frame: LiveCameraFrame?
        let feed = LiveCameraFeed(config: config, transport: { _ in
            calls += 1
            if calls == 1 { return (data, reply) }
            throw URLError(.notConnectedToInternet)
        }, interval: 0.02) { frame = $0; state = $1 }
        feed.start()
        await until { state == .live }
        await until { state == .unavailable }
        XCTAssertNil(frame)
        feed.stop()
    }

    func testBackendCameraIsIndependentOfSampleCatalogAndStopsWithSource() async {
        let data = jpeg(); let reply = response()
        var calls = 0
        let source = BackendRobotSource(config: config, cameraTransport: { _ in
            calls += 1; return (data, reply)
        })
        XCTAssertFalse(source.liveCameraIsSample)
        XCTAssertEqual(calls, 0, "Home and status polling must not start camera requests")
        source.beginLiveView()
        await until { source.liveCameraState == .live }
        XCTAssertNotNil(source.liveFrame)
        source.stop()
        XCTAssertNil(source.liveFrame)
        XCTAssertNil(source.liveCameraFrame)
        XCTAssertEqual(source.liveCameraState, .idle)
        let stoppedCalls = calls
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, stoppedCalls)
    }
}
