import XCTest
import simd
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(MLEncoders)
@testable import MLEncoders
#endif
#if canImport(PlannerCore)
@testable import PlannerCore
#endif
#if canImport(Retrieval)
import Retrieval
#endif
#if canImport(FindExecutor)
import FindExecutor
#endif
#if canImport(Memory)
import Memory
#endif

// Helper names are prefixed FL73 because RecallTests compiles every test file into one module.

struct FL73Pixels: FrameCropping {
    var red: Bool
    func crop(_ rect: PixelRect) -> RawImage? {
        RawImage(width: rect.width, height: rect.height,
                 rgba: (0..<(rect.width * rect.height)).flatMap { _ in [red ? 220 : 10, 0, 0, 255] })
    }
}

/// Fixed pinhole camera at the origin looking down -z; every call is a new frame 0.25 s later.
final class FL73Frames: CameraFrameSource {
    var calls = 0
    var red: Bool
    var cameraToWorld = matrix_identity_float4x4
    init(red: Bool) { self.red = red }
    func latestFrame() -> CameraFrame? {
        calls += 1
        let g = CameraGeometry(cameraToWorld: cameraToWorld, fx: 1000, fy: 1000, cx: 960, cy: 720,
                               imageWidth: 1920, imageHeight: 1440, timestamp: Double(calls) * 0.25)
        return CameraFrame(geometry: g, pixels: FL73Pixels(red: red))
    }
}

/// Image model: a red crop embeds as axis 0, anything else as axis 1.
struct FL73ImageRunner: ImageModelRunning {
    func run(image: RawImage) throws -> [Float] {
        var v = [Float](repeating: 0, count: 512)
        v[image.rgba[0] > 100 ? 0 : 1] = 1
        return v
    }
}
struct FL73TextEncoder: TextEncoder {
    func encode(_ text: String) throws -> [Float] { var v = [Float](repeating: 0, count: 512); v[0] = 1; return v }
}

final class FindLoopWiringTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("fl73-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }
    private func install(_ assets: [ModelAsset], in dir: URL) throws {
        for a in assets { try Data("x".utf8).write(to: dir.appendingPathComponent(a.rawValue)) }
    }
    private let fake: EncoderProviders.Builder = { _ in (FL73TextEncoder(), CoreMLImageEmbedder(runner: FL73ImageRunner())) }

    // MARK: provider selection

    func testAllAssetsPresentSelectsRealProvider() throws {
        let dir = try tempDir(); try install(ModelAsset.allCases, in: dir)
        var builtFrom: ModelLocations?
        let p = EncoderProviders.makeDefault(locator: ModelLocator(bundles: [], applicationSupport: dir),
                                             build: { builtFrom = $0; return try self.fake($0) })
        let set = p.encoders()
        XCTAssertTrue(set.isAvailable)
        XCTAssertNil(set.unavailableMessage)
        XCTAssertNotNil(set.imageModel, "perception loop needs the same image model")
        XCTAssertTrue(set.images is ArrivalCropEmbedder)
        XCTAssertEqual(builtFrom?.vocab.lastPathComponent, "vocab.json")
        XCTAssertFalse(set.text is ModelsMissingEncoder)
    }

    func testOneAssetMissingFallsBackAndNamesIt() throws {
        let dir = try tempDir(); try install(ModelAsset.allCases.filter { $0 != .merges }, in: dir)
        var built = false
        let set = EncoderProviders.makeDefault(locator: ModelLocator(bundles: [], applicationSupport: dir),
                                               build: { built = true; return try self.fake($0) }).encoders()
        XCTAssertFalse(set.isAvailable); XCTAssertFalse(built, "nothing is loaded when a file is missing")
        XCTAssertTrue(set.unavailableMessage?.contains("tokenizer merges") == true, "\(set.unavailableMessage ?? "nil")")
        XCTAssertFalse(set.unavailableMessage?.contains("text model") == true)
        XCTAssertTrue(set.diagnostic?.contains("merges.txt") == true)
        XCTAssertTrue(set.images is ModelsMissingEncoder)
    }

    func testNoAssetsFallsBackListingEverything() throws {
        let dir = try tempDir()
        let set = EncoderProviders.makeDefault(locator: ModelLocator(bundles: [], applicationSupport: dir), build: fake).encoders()
        XCTAssertFalse(set.isAvailable)
        let msg = try XCTUnwrap(set.unavailableMessage)
        for n in ["text model", "image model", "tokenizer vocabulary", "tokenizer merges"] { XCTAssertTrue(msg.contains(n), msg) }
        XCTAssertNil(set.imageModel)
    }

    func testFilesPresentButLoadingFailsFallsBackWithDiagnostic() throws {
        let dir = try tempDir(); try install(ModelAsset.allCases, in: dir)
        struct Boom: Error {}
        let set = EncoderProviders.makeDefault(locator: ModelLocator(bundles: [], applicationSupport: dir), build: { _ in throw Boom() }).encoders()
        XCTAssertFalse(set.isAvailable)
        XCTAssertTrue(set.unavailableMessage?.contains("would not load") == true)
        XCTAssertNotNil(set.diagnostic)
    }

    func testRealBuilderRejectsGarbageFilesInsteadOfCrashing() throws {
        let dir = try tempDir(); try install(ModelAsset.allCases, in: dir)
        let set = EncoderProviders.makeDefault(locator: ModelLocator(bundles: [], applicationSupport: dir)).encoders()
        XCTAssertFalse(set.isAvailable, "garbage vocab/model files must fall back, not crash")
    }

    // MARK: coordinator-level find with a fake camera

    private func rig(frames: FL73Frames) throws -> CoordIntegrationRig {
        let embedder = ArrivalCropEmbedder(frames: frames, embedder: CoreMLImageEmbedder(runner: FL73ImageRunner()))
        let enc = StaticEncoderProvider(set: EncoderSet(text: FL73TextEncoder(), images: embedder, isAvailable: true, unavailableMessage: nil))
        let rig = try CoordIntegrationRig(encoders: enc)
        var e = [Float](repeating: 0, count: 512); e[0] = 1     // stored crop looks "red"
        try rig.tracks.upsert(Track(id: "obj_1", position: SIMD3(0, 0, -2), embedding: e, sightings: 3, persistence: 0.8))
        return rig
    }

    func testTypedFindAcceptsWhenArrivalCropMatchesStoredEmbedding() async throws {
        let frames = FL73Frames(red: true)
        let rig = try rig(frames: frames)
        try await rig.coordinator.execute(.findObject(description: "red mug"))
        XCTAssertTrue(rig.speaker.said.contains { $0.hasPrefix("Found red mug") }, "\(rig.speaker.said)")
        XCTAssertGreaterThanOrEqual(frames.calls, 3, "looked at three spaced frames")
        XCTAssertEqual(rig.coordinator.status, .idle)
    }

    func testTypedFindRejectsWhenArrivalCropLooksDifferent() async throws {
        let rig = try rig(frames: FL73Frames(red: false))
        try await rig.coordinator.execute(.findObject(description: "red mug"))
        XCTAssertFalse(rig.speaker.said.contains { $0.hasPrefix("Found") }, "\(rig.speaker.said)")
        XCTAssertFalse(rig.speaker.said.isEmpty)
        XCTAssertEqual(rig.coordinator.status, .idle)
    }

    func testTypedFindTreatsPointOutOfViewAsNotFoundNotACrash() async throws {
        let frames = FL73Frames(red: true)
        frames.cameraToWorld = simd_float4x4(columns: (SIMD4(-1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 0, 0, 1)))  // looking backwards
        let rig = try rig(frames: frames)
        try await rig.coordinator.execute(.findObject(description: "red mug"))
        XCTAssertFalse(rig.speaker.said.contains { $0.hasPrefix("Found") }, "\(rig.speaker.said)")
        XCTAssertEqual(rig.coordinator.status, .idle)
    }
}
