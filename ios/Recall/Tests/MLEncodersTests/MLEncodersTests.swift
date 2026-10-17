import XCTest
import Foundation
#if canImport(Memory)
import Memory
#endif
#if canImport(Retrieval)
import Retrieval
#endif
#if canImport(FindExecutor)
import FindExecutor
#endif
#if canImport(PerceptionCore)
import PerceptionCore
#endif
#if canImport(MLEncoders)
@testable import MLEncoders
#endif

// Helper names are prefixed ML32 because RecallTests compiles every test file into one module.
struct ML32TextRunner: TextModelRunning {
    var out: [Float]
    var seen: (([Int32]) -> Void)? = nil
    func run(tokens: [Int32]) throws -> [Float] { seen?(tokens); return out }
}
struct ML32ImageRunner: ImageModelRunning {
    var out: [Float]
    var seen: ((RawImage) -> Void)? = nil
    func run(image: RawImage) throws -> [Float] { seen?(image); return out }
}
struct ML32Provider: LookCropProviding {
    func crops(around position: SIMD3<Float>, count: Int, cropScale: Float) async throws -> [RawImage] {
        (0..<count).map { _ in RawImage(width: 2, height: 2, rgba: [UInt8](repeating: 7, count: 16)) }
    }
}

func ml32TinyTokenizer() throws -> CLIPTokenizer {
    // chars: c a t, each also with </w>; merges: c+a -> ca, ca+t</w> -> cat</w>
    var vocab: [String: Int] = [:]
    for (i, s) in ["c", "a", "t", "c</w>", "a</w>", "t</w>", "ca", "cat</w>", "<start_of_text>", "<end_of_text>"].enumerated() { vocab[s] = i + 1 }
    return try CLIPTokenizer(vocab: vocab, merges: [("c", "a"), ("ca", "t</w>")])
}

final class MLEncodersTests: XCTestCase {
    // MARK: tokenizer (hand-made vocab)
    func testTinyBPEMergesByRankAndPads() throws {
        let t = try ml32TinyTokenizer()
        let ids = t.encode("  CAT  ")
        XCTAssertEqual(ids.count, 77)
        XCTAssertEqual(Array(ids.prefix(3)), [9, 8, 10])   // start, cat</w>, end
        XCTAssertTrue(ids.dropFirst(3).allSatisfy { $0 == 0 })
    }

    func testTinyUnmergedWordKeepsSymbols() throws {
        let t = try ml32TinyTokenizer()
        // "at": no merge applies; symbols a, t</w>
        XCTAssertEqual(Array(t.encode("at").prefix(4)), [9, 2, 6, 10])
    }

    func testEmptyIsStartEndPad() throws {
        let ids = try ml32TinyTokenizer().encode("")
        XCTAssertEqual(Array(ids.prefix(2)), [9, 10])
        XCTAssertEqual(ids.count, 77)
    }

    func testTruncationKeepsEndToken() throws {
        let ids = try ml32TinyTokenizer().encode(String(repeating: "cat ", count: 200))
        XCTAssertEqual(ids.count, 77)
        XCTAssertEqual(ids.first, 9)
        XCTAssertEqual(ids.last, 10)
        XCTAssertEqual(ids[1], 8)
    }

    func testByteToUnicodeMapMatchesGPT2() {
        let m = CLIPTokenizer.makeByteToUnicode()
        XCTAssertEqual(m.count, 256)
        XCTAssertEqual(m[0x61], "a")
        XCTAssertEqual(m[0x20], "\u{120}")   // space -> Ġ
        XCTAssertEqual(Set(m.values).count, 256)
    }

    func testMissingSpecialTokensThrows() {
        XCTAssertThrowsError(try CLIPTokenizer(vocab: ["a": 1], merges: []))
    }

    func testLoadsFromDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ml32-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let vocab = ["c": 1, "a": 2, "t</w>": 3, "ca": 4, "cat</w>": 5, "<start_of_text>": 6, "<end_of_text>": 7]
        try JSONEncoder().encode(vocab).write(to: dir.appendingPathComponent("vocab.json"))
        try "c a\nca t</w>\n".write(to: dir.appendingPathComponent("merges.txt"), atomically: true, encoding: .utf8)
        let t = try CLIPTokenizer(directory: dir)
        XCTAssertEqual(Array(t.encode("cat").prefix(3)), [6, 5, 7])
        XCTAssertThrowsError(try CLIPTokenizer(directory: dir.appendingPathComponent("nope")))
    }

    // MARK: golden parity with open_clip (PR 7 fixture)
    private func golden() throws -> [(text: String, ids: [Int32])] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden_tokens.json")
        let arr = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        return arr.map { ($0["text"] as! String, ($0["ids"] as! [Int]).map { Int32($0) }) }
    }

    func testGoldenFixtureShape() throws {
        let g = try golden()
        XCTAssertEqual(g.count, 10)
        XCTAssertTrue(g.allSatisfy { $0.ids.count == 77 })
    }

    /// Runs only when RECALL_TOKENIZER_DIR points at a directory holding the real vocab.json + merges.txt
    /// (produced by ml/conversion/export_tokenizer.py; not committed).
    func testRealVocabMatchesOpenCLIPGolden() throws {
        guard let dir = ProcessInfo.processInfo.environment["RECALL_TOKENIZER_DIR"] else {
            throw XCTSkip("RECALL_TOKENIZER_DIR not set; real-vocab golden parity not run")
        }
        let t = try CLIPTokenizer(directory: URL(fileURLWithPath: dir))
        for (text, ids) in try golden() { XCTAssertEqual(t.encode(text), ids, "phrase: \(text)") }
    }

    // MARK: embeddings
    func testTextEncoderNormalizesAndTokenizes() throws {
        var captured: [Int32] = []
        let enc = CoreMLTextEncoder(tokenizer: try ml32TinyTokenizer(),
                                    runner: ML32TextRunner(out: [Float](repeating: 3, count: 512), seen: { captured = $0 }))
        let v = try enc.encode("cat")
        XCTAssertEqual(captured.count, 77)
        XCTAssertEqual(v.count, 512)
        XCTAssertEqual(v.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-4)
    }

    func testBadModelOutputsThrow() throws {
        let tok = try ml32TinyTokenizer()
        XCTAssertThrowsError(try CoreMLTextEncoder(tokenizer: tok, runner: ML32TextRunner(out: [1, 2])).encode("cat")) {
            XCTAssertEqual($0 as? EncoderError, .wrongOutputSize(expected: 512, got: 2))
        }
        XCTAssertThrowsError(try CoreMLTextEncoder(tokenizer: tok, runner: ML32TextRunner(out: [Float](repeating: 0, count: 512))).encode("cat")) {
            XCTAssertEqual($0 as? EncoderError, .zeroVector)
        }
    }

    func testImageEmbedderPreprocessesAndNormalizes() throws {
        var seen: [RawImage] = []
        let emb = CoreMLImageEmbedder(runner: ML32ImageRunner(out: [Float](repeating: 2, count: 512), seen: { seen.append($0) }))
        let crop = RawImage(width: 40, height: 20, rgba: [UInt8](repeating: 100, count: 40 * 20 * 4))
        let out = try emb.embed([crop, crop])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-4)
        XCTAssertEqual(seen.map { [$0.width, $0.height] }, [[256, 256], [256, 256]])
    }

    func testLookEmbedderUsesProviderCrops() async throws {
        let emb = CoreMLLookEmbedder(provider: ML32Provider(),
                                     embedder: CoreMLImageEmbedder(runner: ML32ImageRunner(out: [Float](repeating: 1, count: 512))))
        let r = try await emb.captureEmbeddings(around: SIMD3<Float>(0, 0, 1), count: 3, cropScale: 1.2)
        XCTAssertEqual(r.count, 3)
    }

    // MARK: preprocessing
    func testCenterCropTakesMiddleSquare() {
        // 4x2 image: left half red, right half blue. Center crop of the 2x2 middle => left col red, right col blue.
        var px: [UInt8] = []
        for _ in 0..<2 { for x in 0..<4 { px += x < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255] } }
        let out = ImagePreprocessing.prepare(RawImage(width: 4, height: 2, rgba: px), mode: .centerCrop, size: 2)
        // Middle square covers x in 1..<3: one red column, one blue column.
        XCTAssertEqual(Array(out.rgba[0..<3]), [255, 0, 0])
        XCTAssertEqual(Array(out.rgba[4..<7]), [0, 0, 255])
    }

    func testSquashKeepsWholeImageAndConstantStaysConstant() {
        let img = RawImage(width: 10, height: 3, rgba: [UInt8](repeating: 77, count: 10 * 3 * 4))
        let out = ImagePreprocessing.prepare(img, mode: .squash)
        XCTAssertEqual(out.width, 256)
        XCTAssertTrue(stride(from: 0, to: out.rgba.count, by: 4).allSatisfy { out.rgba[$0] == 77 && out.rgba[$0 + 1] == 77 })
    }

    func testBytesAreNotScaledButCHWHelperIs() {
        let img = RawImage(width: 1, height: 1, rgba: [255, 0, 51, 255])
        XCTAssertEqual(ImagePreprocessing.prepare(img, size: 1).rgba, [255, 0, 51, 255])
        XCTAssertEqual(ImagePreprocessing.chwUnitScale(img), [1, 0, 0.2])
    }

    // MARK: locator
    func testLocatorFindsAppSupportAndReportsMissing() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ml32loc-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let loc = ModelLocator(bundles: [], applicationSupport: dir)
        XCTAssertThrowsError(try loc.locateAll()) { e in
            let err = e as? ModelLocatorError
            XCTAssertEqual(err?.missing.count, ModelAsset.allCases.count)
            XCTAssertFalse(err?.spokenMessage.isEmpty ?? true)
        }
        for a in ModelAsset.allCases {
            let u = dir.appendingPathComponent(a.rawValue)
            if a.rawValue.hasSuffix(".mlmodelc") { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
            else { try Data().write(to: u) }
        }
        let found = try loc.locateAll()
        XCTAssertEqual(found.textModel.lastPathComponent, "MobileCLIP_S0_Text.mlmodelc")
        XCTAssertEqual(found.vocab.lastPathComponent, "vocab.json")
        // one asset removed -> only that one is reported
        try fm.removeItem(at: dir.appendingPathComponent("merges.txt"))
        XCTAssertThrowsError(try loc.locateAll()) { XCTAssertEqual(($0 as? ModelLocatorError)?.missing, [.merges]) }
    }
}
