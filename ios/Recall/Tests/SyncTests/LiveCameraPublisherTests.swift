import XCTest
import Foundation
#if canImport(SyncCore)
@testable import SyncCore
#endif

private final class CameraClock {
    private let lock = NSLock()
    private var time: Double = 100
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
    func set(_ value: Double) { lock.lock(); time = value; lock.unlock() }
}

private final class CameraUploads: LiveCameraUploading {
    private let lock = NSLock()
    private var bodies: [Data] = []
    var sent: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    func upload(jpeg: Data) async throws { record(jpeg) }
    private func record(_ jpeg: Data) { lock.lock(); bodies.append(jpeg); lock.unlock() }
}

/// Deliberately ignores cancellation to model a late network completion after stop/resume.
private actor HeldCameraUpload: LiveCameraUploading {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    let began: XCTestExpectation
    init(began: XCTestExpectation) { self.began = began }
    func upload(jpeg: Data) async throws {
        count += 1
        await withCheckedContinuation { c in continuation = c; began.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class LiveCameraPublisherTests: XCTestCase {
    func testFreshnessDuplicatesRateLimitAndInactiveFramesDoNotEncode() async {
        let clock = CameraClock(), uploads = CameraUploads()
        let publisher = LiveCameraPublisher(transport: uploads, clock: clock.now)
        let forbidden: () -> Data? = { XCTFail("dropped frame was encoded"); return nil }
        XCTAssertNil(publisher.offer(timestamp: 100, encode: forbidden))
        publisher.start()
        XCTAssertNil(publisher.offer(timestamp: 98, encode: forbidden))
        XCTAssertNil(publisher.offer(timestamp: 101, encode: forbidden))
        XCTAssertNil(publisher.offer(timestamp: .nan, encode: forbidden))
        let first = publisher.offer(timestamp: 100) { Data([1]) }
        XCTAssertNotNil(first)
        await first?.value
        clock.set(100.5)
        publisher.start() // Repeated runtime start must not bypass throttling.
        XCTAssertNil(publisher.offer(timestamp: 100.5, encode: forbidden))
        clock.set(101)
        XCTAssertNil(publisher.offer(timestamp: 100, encode: forbidden))
        let next = publisher.offer(timestamp: 101) { Data([2]) }
        await next?.value
        XCTAssertEqual(uploads.sent, [Data([1]), Data([2])])
        publisher.stop()
        clock.set(102)
        XCTAssertNil(publisher.offer(timestamp: 102, encode: forbidden))
    }

    func testOnlyOneUploadEvenAcrossStopResumeAndLateCompletion() async {
        let began = expectation(description: "first upload began")
        let uploads = HeldCameraUpload(began: began), clock = CameraClock()
        let publisher = LiveCameraPublisher(transport: uploads, clock: clock.now)
        publisher.start()
        let first = publisher.offer(timestamp: 100) { Data([1]) }
        await fulfillment(of: [began], timeout: 2)
        publisher.stop()
        publisher.start()
        clock.set(101)
        XCTAssertNil(publisher.offer(timestamp: 101) { XCTFail("overlapping encode"); return nil })
        await uploads.release()
        await first?.value
        let count = await uploads.count
        XCTAssertEqual(count, 1)
        // Finishing old work cannot schedule a new frame or silently reactivate a stopped publisher.
        publisher.stop()
        XCTAssertNil(publisher.offer(timestamp: 101) { XCTFail("restarted after stop"); return nil })
    }

    func testStopDuringEncodeDiscardsItsResultAndResumeCanPublishFreshFrame() async {
        let began = expectation(description: "encode began")
        let release = DispatchSemaphore(value: 0)
        let clock = CameraClock(), uploads = CameraUploads()
        let publisher = LiveCameraPublisher(transport: uploads, clock: clock.now)
        publisher.start()
        let first = publisher.offer(timestamp: 100) {
            began.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else { return nil }
            return Data([1])
        }
        await fulfillment(of: [began], timeout: 2)
        publisher.stop()
        publisher.start()
        clock.set(101)
        XCTAssertNil(publisher.offer(timestamp: 101) { XCTFail("second concurrent encode"); return nil })
        release.signal()
        await first?.value
        XCTAssertTrue(uploads.sent.isEmpty)
        let resumed = publisher.offer(timestamp: 101) { Data([2]) }
        XCTAssertNotNil(resumed)
        await resumed?.value
        XCTAssertEqual(uploads.sent, [Data([2])])
        publisher.stop()
    }

    func testOversizedEmptyAndStaleAfterEncodingAreDiscarded() async {
        let clock = CameraClock(), uploads = CameraUploads()
        let publisher = LiveCameraPublisher(transport: uploads, clock: clock.now)
        publisher.start()
        let oversized = publisher.offer(timestamp: 100) { Data(count: LiveCameraPublisher.maxBytes + 1) }
        await oversized?.value
        clock.set(101)
        let empty = publisher.offer(timestamp: 101) { Data() }
        await empty?.value
        clock.set(102)
        let stale = publisher.offer(timestamp: 102) { clock.set(104); return Data([1]) }
        await stale?.value
        XCTAssertTrue(uploads.sent.isEmpty)
        clock.set(105)
        let boundary = publisher.offer(timestamp: 105) { Data(count: LiveCameraPublisher.maxBytes) }
        await boundary?.value
        XCTAssertEqual(uploads.sent.first?.count, LiveCameraPublisher.maxBytes)
        publisher.stop()
    }

    func testRequestUsesAuthenticatedRawJPEGWithoutMediaOrQueue() {
        let config = SyncConfig(baseURL: URL(string: "https://robot.invalid/")!, token: "test-token")
        let request = URLSessionLiveCameraTransport(config: config).makeRequest()
        XCTAssertEqual(request.url?.absoluteString, "https://robot.invalid/api/camera/frame")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(request.httpBody)
    }

    func testFailedUploadIsNotRetriedAndANewFrameCanFollow() async {
        actor FailingUpload: LiveCameraUploading {
            private(set) var attempts = 0
            func upload(jpeg: Data) async throws { attempts += 1; throw URLError(.notConnectedToInternet) }
        }
        let uploads = FailingUpload(), clock = CameraClock()
        let publisher = LiveCameraPublisher(transport: uploads, clock: clock.now)
        publisher.start()
        let first = publisher.offer(timestamp: 100) { Data([1]) }
        await first?.value
        let firstCount = await uploads.attempts
        XCTAssertEqual(firstCount, 1)
        clock.set(101)
        let next = publisher.offer(timestamp: 101) { Data([2]) }
        XCTAssertNotNil(next)
        await next?.value
        let nextCount = await uploads.attempts
        XCTAssertEqual(nextCount, 2)
        publisher.stop()
    }
}
