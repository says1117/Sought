import XCTest
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(MLEncoders)
@testable import MLEncoders
#endif

// Helper names are prefixed PC74 because RecallTests compiles every test file into one module.
final class ProviderConfigTests: XCTestCase {
    /// The default builder (`EncoderProviders.realBuilder`) with the real CLIP ViT-B/32 assets: the located 224 px config
    /// must reach the image embedder, and a crop must embed without Core ML rejecting its size.
    /// RECALL_MODELS_DIR = folder with both .mlpackage, model_config.json, vocab.json, merges.txt (install folder).
    func testDefaultBuilderCarriesClipConfigAndEmbedsAt224() throws {
        #if canImport(CoreML)
        guard let models = ProcessInfo.processInfo.environment["RECALL_MODELS_DIR"] else { throw XCTSkip("RECALL_MODELS_DIR not set") }
        let fm = FileManager.default
        let cache = fm.temporaryDirectory.appendingPathComponent("pc74-\(UUID().uuidString)")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: cache) }
        for f in try fm.contentsOfDirectory(atPath: models) {
            try fm.copyItem(at: URL(fileURLWithPath: models).appendingPathComponent(f), to: cache.appendingPathComponent(f))
        }
        let locator = ModelLocator(bundles: [], applicationSupport: cache)
        guard try locator.loadConfig().imageSize == 224 else { throw XCTSkip("RECALL_MODELS_DIR is not the CLIP 224 install") }
        let set = EncoderProviders.makeDefault(locator: locator).encoders()
        XCTAssertTrue(set.isAvailable, set.diagnostic ?? "")
        let image = try XCTUnwrap(set.imageModel)
        XCTAssertEqual(image.config.imageSize, 224)
        let crop = RawImage(width: 300, height: 200, rgba: [UInt8](repeating: 120, count: 300 * 200 * 4))
        XCTAssertEqual(try image.embedOne(crop).count, 512)
        XCTAssertEqual(try set.text.encode("a cat").count, 512)
        #else
        throw XCTSkip("CoreML unavailable")
        #endif
    }
}
