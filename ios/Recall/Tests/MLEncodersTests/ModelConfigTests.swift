import XCTest
import Foundation
#if canImport(MLEncoders)
@testable import MLEncoders
#endif

// Helper names are prefixed ML74 because RecallTests compiles every test file into one module.
private func ml74Json(_ over: [String: Any] = [:], drop: [String] = []) -> Data {
    var d: [String: Any] = ["name": "clip-vit-b32-laion2b", "image_size": 224, "embedding_dim": 512, "context_length": 77,
                            "normalization_baked": true, "image_model": "CLIP_ViT_B32_Image", "text_model": "CLIP_ViT_B32_Text"]
    for (k, v) in over { d[k] = v }
    for k in drop { d[k] = nil }
    return try! JSONSerialization.data(withJSONObject: d)
}

final class ModelConfigTests: XCTestCase {
    func testParsesTheConverterOutput() throws {
        let c = try ModelConfig.parse(ml74Json())
        XCTAssertEqual(c, ModelConfig(name: "clip-vit-b32-laion2b", imageSize: 224, embeddingDim: 512, contextLength: 77,
                                      normalizationBaked: true, imageModel: "CLIP_ViT_B32_Image", textModel: "CLIP_ViT_B32_Text"))
    }

    func testDefaultIsMobileClipS0() {
        let c = ModelConfig.mobileClipS0
        XCTAssertEqual([c.imageSize, c.embeddingDim, c.contextLength], [256, 512, 77])
        XCTAssertEqual(c.imageModel, "MobileCLIP_S0_Image")
        XCTAssertEqual(ImagePreprocessing.inputSize, 256)
    }

    func testModelNamesDefaultWhenOmitted() throws {
        let c = try ModelConfig.parse(ml74Json(drop: ["image_model", "text_model"]))
        XCTAssertEqual(c.imageModel, "MobileCLIP_S0_Image")
        XCTAssertEqual(c.textModel, "MobileCLIP_S0_Text")
    }

    func testInvalidConfigsAreRejectedWithAReason() {
        let bad: [(Data, String)] = [
            (Data("not json".utf8), "not valid"),
            (ml74Json(drop: ["image_size"]), "not valid"),
            (ml74Json(["image_size": 0]), "image_size"),
            (ml74Json(["image_size": 4096]), "image_size"),
            (ml74Json(["embedding_dim": 0]), "embedding_dim"),
            (ml74Json(["context_length": 32]), "context_length"),
            (ml74Json(["normalization_baked": false]), "normalization_baked"),
            (ml74Json(["image_model": "../evil"]), "plain base name"),
            (ml74Json(["text_model": "T.mlmodelc"]), "plain base name"),
        ]
        for (data, word) in bad {
            XCTAssertThrowsError(try ModelConfig.parse(data), word) { e in
                XCTAssertTrue((e as? ModelConfigError)?.reason.contains(word) ?? false, "\(e) should mention \(word)")
            }
        }
    }

    // MARK: preprocessing shapes
    func testPrepareProducesTheConfiguredSquare() {
        let img = RawImage(width: 300, height: 200, rgba: [UInt8](repeating: 9, count: 300 * 200 * 4))
        for size in [224, 256] {
            for mode in [CropFitMode.centerCrop, .squash] {
                let out = ImagePreprocessing.prepare(img, mode: mode, size: size)
                XCTAssertEqual([out.width, out.height, out.rgba.count], [size, size, size * size * 4])
            }
        }
        XCTAssertEqual(ImagePreprocessing.prepare(img).width, 256, "no size argument keeps the MobileCLIP default")
    }

    func testImageEmbedderUsesConfigImageSizeAndDimension() throws {
        var seen: [RawImage] = []
        let cfg = try ModelConfig.parse(ml74Json(["embedding_dim": 8]))
        let emb = CoreMLImageEmbedder(runner: ML74Runner(out: [Float](repeating: 1, count: 8), seen: { seen.append($0) }), config: cfg)
        let v = try emb.embedOne(RawImage(width: 40, height: 20, rgba: [UInt8](repeating: 100, count: 40 * 20 * 4)))
        XCTAssertEqual(v.count, 8)
        XCTAssertEqual(seen.map { [$0.width, $0.height] }, [[224, 224]])
        // a 512-d output from a model configured for 8 is rejected, not passed through
        let wrong = CoreMLImageEmbedder(runner: ML74Runner(out: [Float](repeating: 1, count: 512)), config: cfg)
        XCTAssertThrowsError(try wrong.embedOne(RawImage(width: 4, height: 4, rgba: [UInt8](repeating: 1, count: 64)))) {
            XCTAssertEqual($0 as? EncoderError, .wrongOutputSize(expected: 8, got: 512))
        }
    }

    func testLookEmbedderPathUsesConfigSize() async throws {
        var seen: [RawImage] = []
        let cfg = try ModelConfig.parse(ml74Json())
        let inner = CoreMLImageEmbedder(runner: ML74Runner(out: [Float](repeating: 1, count: 512), seen: { seen.append($0) }), config: cfg)
        let look = CoreMLLookEmbedder(provider: ML74Provider(), embedder: inner)
        let out = try await look.captureEmbeddings(around: .zero, count: 2, cropScale: 1.5)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(seen.map(\.width), [224, 224])
    }

    // MARK: locator
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ml74-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testLocatorWithoutConfigFileDefaultsToMobileClip() throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let loc = ModelLocator(bundles: [], applicationSupport: dir)
        XCTAssertEqual(try loc.loadConfig(), .mobileClipS0)
    }

    func testLocatorReadsConfigAndLooksForTheNamedModels() throws {
        let fm = FileManager.default
        let dir = try tmp(); defer { try? fm.removeItem(at: dir) }
        try ml74Json().write(to: dir.appendingPathComponent("model_config.json"))
        let loc = ModelLocator(bundles: [], applicationSupport: dir)
        // models missing: error names the configured files, not the MobileCLIP ones
        XCTAssertThrowsError(try loc.locateAll()) { e in
            let err = e as? ModelLocatorError
            XCTAssertEqual(err?.missingNames, ["CLIP_ViT_B32_Text.mlmodelc", "CLIP_ViT_B32_Image.mlmodelc", "vocab.json", "merges.txt"])
            XCTAssertTrue(err?.description.contains("CLIP_ViT_B32_Image.mlmodelc") ?? false)
            XCTAssertFalse(err?.description.contains("MobileCLIP_S0") ?? true)
        }
        for n in ["CLIP_ViT_B32_Text.mlmodelc", "CLIP_ViT_B32_Image.mlmodelc"] {
            try fm.createDirectory(at: dir.appendingPathComponent(n), withIntermediateDirectories: true)
        }
        try Data().write(to: dir.appendingPathComponent("vocab.json")); try Data().write(to: dir.appendingPathComponent("merges.txt"))
        let found = try loc.locateAll()
        XCTAssertEqual(found.config.imageSize, 224)
        XCTAssertEqual(found.imageModel.lastPathComponent, "CLIP_ViT_B32_Image.mlmodelc")
        // MobileCLIP-named models alone do not satisfy a CLIP config
        try fm.removeItem(at: dir.appendingPathComponent("CLIP_ViT_B32_Text.mlmodelc"))
        try fm.createDirectory(at: dir.appendingPathComponent("MobileCLIP_S0_Text.mlmodelc"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try loc.locateAll()) { XCTAssertEqual(($0 as? ModelLocatorError)?.missing, [.textModel]) }
    }

    func testLocatorCompilesConfiguredPackage() throws {
        let fm = FileManager.default
        let dir = try tmp(); defer { try? fm.removeItem(at: dir) }
        try ml74Json().write(to: dir.appendingPathComponent("model_config.json"))
        for n in ["CLIP_ViT_B32_Text.mlpackage", "CLIP_ViT_B32_Image.mlpackage"] {
            try fm.createDirectory(at: dir.appendingPathComponent(n), withIntermediateDirectories: true)
        }
        try Data().write(to: dir.appendingPathComponent("vocab.json")); try Data().write(to: dir.appendingPathComponent("merges.txt"))
        var compiled: [String] = []
        let loc = ModelLocator(bundles: [], applicationSupport: dir, compiler: { pkg in
            compiled.append(pkg.lastPathComponent)
            let out = fm.temporaryDirectory.appendingPathComponent("ml74c-\(UUID().uuidString).mlmodelc")
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            return out
        })
        let found = try loc.locateAll()
        XCTAssertEqual(Set(compiled), ["CLIP_ViT_B32_Text.mlpackage", "CLIP_ViT_B32_Image.mlpackage"])
        XCTAssertEqual(found.textModel.lastPathComponent, "CLIP_ViT_B32_Text.mlmodelc")
    }

    func testLocatorThrowsOnInvalidConfigInsteadOfFallingBack() throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{\"name\": 3}".utf8).write(to: dir.appendingPathComponent("model_config.json"))
        let loc = ModelLocator(bundles: [], applicationSupport: dir)
        XCTAssertThrowsError(try loc.locateAll()) { e in
            XCTAssertTrue(e is ModelConfigError)
            XCTAssertTrue("\(e)".contains("model_config.json"))
        }
        try Data().write(to: dir.appendingPathComponent("model_config.json"))   // empty file is invalid too
        XCTAssertThrowsError(try loc.loadConfig())
    }
}

private struct ML74Runner: ImageModelRunning {
    var out: [Float]
    var seen: ((RawImage) -> Void)? = nil
    func run(image: RawImage) throws -> [Float] { seen?(image); return out }
}
private struct ML74Provider: LookCropProviding {
    func crops(around position: SIMD3<Float>, count: Int, cropScale: Float) async throws -> [RawImage] {
        (0..<count).map { _ in RawImage(width: 50, height: 30, rgba: [UInt8](repeating: 7, count: 50 * 30 * 4)) }
    }
}
