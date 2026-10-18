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
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
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

/// The pre-fix resize (plain bilinear, no antialiasing), kept only so the measurement test can report old vs new.
func ml32LegacyBilinear(_ image: RawImage, size: Int = 256) -> RawImage {
    let w = Double(image.width), h = Double(image.height)
    let side = min(w, h)
    let sw = side, sh = side, sx = (w - side) / 2, sy = (h - side) / 2
    func sample(_ x: Int, _ y: Int, _ c: Int) -> Double {
        let cx = max(0, min(image.width - 1, x)), cy = max(0, min(image.height - 1, y))
        return Double(image.rgba[(cy * image.width + cx) * 4 + c])
    }
    var out = [UInt8](repeating: 255, count: size * size * 4)
    for y in 0..<size {
        let fy = sy + (Double(y) + 0.5) * sh / Double(size) - 0.5
        let y0 = Int(fy.rounded(.down)), ty = fy - Double(y0)
        for x in 0..<size {
            let fx = sx + (Double(x) + 0.5) * sw / Double(size) - 0.5
            let x0 = Int(fx.rounded(.down)), tx = fx - Double(x0)
            for c in 0..<3 {
                let top = sample(x0, y0, c) * (1 - tx) + sample(x0 + 1, y0, c) * tx
                let bot = sample(x0, y0 + 1, c) * (1 - tx) + sample(x0 + 1, y0 + 1, c) * tx
                out[(y * size + x) * 4 + c] = UInt8(max(0, min(255, (top * (1 - ty) + bot * ty).rounded())))
            }
        }
    }
    return RawImage(width: size, height: size, rgba: out)
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

    /// Synthetic vocab with exactly the real sizes and special ids (not the real CLIP vocab).
    private func ml32FullSizeFiles(dropMerges: Int = 0, vocabEntries: Int? = nil, swapSpecials: Bool = false,
                                   dropByteSymbol: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ml32full-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var vocab: [String: Int] = [:]
        var syms = Array(CLIPTokenizer.makeByteToUnicode().values.sorted())
        if dropByteSymbol { syms.removeFirst() }
        for s in syms { vocab[s] = vocab.count; vocab[s + "</w>"] = vocab.count }
        let mergeCount = CLIPTokenizer.expectedMergeCount - dropMerges
        var lines: [String] = []
        for i in 0..<CLIPTokenizer.expectedMergeCount {
            if i < mergeCount { lines.append("m \(i)") }
            vocab["m\(i)"] = vocab.count
        }
        if dropByteSymbol { for _ in 0..<2 { vocab["pad-\(vocab.count)"] = vocab.count } }
        vocab["<start_of_text>"] = swapSpecials ? 49_407 : 49_406
        vocab["<end_of_text>"] = swapSpecials ? 49_406 : 49_407
        if let n = vocab.count as Int?, let want = vocabEntries, want < n {
            for k in vocab.keys.filter({ $0.hasPrefix("m") && $0.count > 1 }).prefix(n - want) { vocab[k] = nil }
        }
        try JSONEncoder().encode(vocab).write(to: dir.appendingPathComponent("vocab.json"))
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("merges.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    func testLoadsValidatedFullSizeFiles() throws {
        let dir = try ml32FullSizeFiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = try CLIPTokenizer(directory: dir)
        XCTAssertTrue(t.isValidated)
        XCTAssertEqual(t.startID, 49_406); XCTAssertEqual(t.endID, 49_407)
        XCTAssertEqual(t.encode("hi").count, 77)
        XCTAssertEqual(try t.encodeChecked("hi").first, 49_406)
        XCTAssertThrowsError(try CLIPTokenizer(directory: dir.appendingPathComponent("nope"))) {
            guard case CLIPTokenizerError.fileMissing = $0 else { return XCTFail("\($0)") }
        }
    }

    func testRealFilesAreValidated() throws {
        func expect(_ dir: URL, _ check: (CLIPTokenizerError) -> Bool, _ label: String) throws {
            defer { try? FileManager.default.removeItem(at: dir) }
            XCTAssertThrowsError(try CLIPTokenizer(directory: dir), label) { e in
                XCTAssertTrue((e as? CLIPTokenizerError).map(check) ?? false, "\(label): \(e)")
            }
        }
        try expect(try ml32FullSizeFiles(dropMerges: 1), { if case .wrongMergeCount(48_894, 48_893) = $0 { return true }; return false }, "truncated merges")
        try expect(try ml32FullSizeFiles(vocabEntries: 49_000), { if case .wrongVocabSize(49_408, 49_000) = $0 { return true }; return false }, "truncated vocab")
        try expect(try ml32FullSizeFiles(swapSpecials: true), { if case .wrongSpecialTokenIDs = $0 { return true }; return false }, "swapped specials")
        try expect(try ml32FullSizeFiles(dropByteSymbol: true), { if case .missingByteSymbol = $0 { return true }; return false }, "missing byte symbol")
        // the hand-made 7-entry vocab is rejected by the file loader (it is only for init(vocab:merges:))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ml32tiny-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(["c": 1, "<start_of_text>": 2, "<end_of_text>": 3]).write(to: dir.appendingPathComponent("vocab.json"))
        try "c a\n".write(to: dir.appendingPathComponent("merges.txt"), atomically: true, encoding: .utf8)
        try expect(dir, { if case .wrongVocabSize = $0 { return true }; return false }, "tiny vocab from files")
    }

    func testMergeResultMissingFromVocabIsRejected() throws {
        var vocab: [String: Int] = [:]
        for s in CLIPTokenizer.makeByteToUnicode().values.sorted() { vocab[s] = vocab.count; vocab[s + "</w>"] = vocab.count }
        var merges: [(String, String)] = []
        for i in 0..<CLIPTokenizer.expectedMergeCount { merges.append(("m", "\(i)")); vocab["m\(i)"] = vocab.count }
        vocab["<start_of_text>"] = 49_406; vocab["<end_of_text>"] = 49_407
        XCTAssertNoThrow(try CLIPTokenizer.validate(vocab: vocab, merges: merges))
        merges[5] = ("zz", "top")
        XCTAssertThrowsError(try CLIPTokenizer.validate(vocab: vocab, merges: merges)) {
            XCTAssertEqual($0 as? CLIPTokenizerError, .mergeResultNotInVocab("zztop"))
        }
    }

    func testUnvalidatedTinyVocabStillWorksAndCheckedSurfacesDroppedSymbols() throws {
        let t = try ml32TinyTokenizer()
        XCTAssertFalse(t.isValidated)
        XCTAssertEqual(Array(t.encode("cat").prefix(3)), [9, 8, 10])
        // "z" is not in the tiny vocab: encode drops it silently, encodeChecked throws
        XCTAssertEqual(Array(t.encode("z").prefix(2)), [9, 10])
        XCTAssertThrowsError(try t.encodeChecked("z")) { guard case CLIPTokenizerError.unknownSymbol = $0 else { return XCTFail("\($0)") } }
    }

    // MARK: text cleanup (ftfy + html.unescape parity; expected strings checked against open_clip's tokenizer)
    func testCleanupNFCComposesDecomposedAccents() {
        XCTAssertEqual(CLIPTextCleaning.clean("e\u{0301}cole"), "\u{E9}cole")
    }
    func testCleanupExpandsLigatures() {
        XCTAssertEqual(CLIPTextCleaning.clean("\u{FB01}sh \u{FB02}our \u{FB03}"), "fish flour ffi")
        XCTAssertEqual(CLIPTextCleaning.clean("\u{FB05}"), "\u{17F}t")   // ftfy gives long-s + t
        XCTAssertEqual(CLIPTextCleaning.clean("\u{0132}\u{0133}"), "IJij")
    }
    func testCleanupUnescapesHTMLTwice() {
        XCTAssertEqual(CLIPTextCleaning.clean("&amp; &lt;b&gt;"), "& <b>")
        XCTAssertEqual(CLIPTextCleaning.clean("&amp;amp; x"), "& x")           // two passes, like html.unescape x2
        XCTAssertEqual(CLIPTextCleaning.clean("&#39;s &quot;hi&quot; &eacute; &#x41;"), "'s \"hi\" \u{E9} A")
        XCTAssertEqual(CLIPTextCleaning.clean("AT&T & co"), "AT&T & co")          // stray ampersands stay
    }
    func testCleanupRemovesNULAndControls() {
        XCTAssertEqual(CLIPTextCleaning.clean("a\u{0}b"), "ab")
        XCTAssertEqual(CLIPTextCleaning.clean("a\u{1}b\u{7}c"), "abc")
        XCTAssertEqual(CLIPTextCleaning.clean("a\tb\nc"), "a\tb\nc")
    }
    func testCleanupFixesMojibakeAndUncurlsQuotes() {
        XCTAssertEqual(CLIPTextCleaning.clean("caf\u{C3}\u{A9}"), "caf\u{E9}")
        XCTAssertEqual(CLIPTextCleaning.clean("caf\u{E9}"), "caf\u{E9}")       // a real é is left alone
        XCTAssertEqual(CLIPTextCleaning.clean("it\u{2019}s \u{201C}q\u{201D}"), "it's \"q\"")
        XCTAssertEqual(CLIPTextCleaning.clean("\u{FF21}\u{FF22}\u{FF43} \u{FF46}"), "ABc f")
    }
    func testCleanupReachesTokenizer() throws {
        let t = try ml32TinyTokenizer()
        XCTAssertEqual(t.encode("c&#97;t"), t.encode("cat"))
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
        XCTAssertEqual(g.count, 11)
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

    /// Optional wider comparison: `extra_golden.json` next to the real vocab (same shape as the fixture,
    /// generated locally from open_clip; see PR 32 notes). Prints the match count.
    func testRealVocabMatchesExtraGoldenIfPresent() throws {
        guard let dir = ProcessInfo.processInfo.environment["RECALL_TOKENIZER_DIR"] else {
            throw XCTSkip("RECALL_TOKENIZER_DIR not set")
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("extra_golden.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no extra_golden.json in RECALL_TOKENIZER_DIR") }
        let arr = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let t = try CLIPTokenizer(directory: URL(fileURLWithPath: dir))
        var bad: [String] = []
        for e in arr {
            let ids = (e["ids"] as! [Int]).map { Int32($0) }
            if t.encode(e["text"] as! String) != ids { bad.append((e["text"] as! String).debugDescription) }
        }
        print("EXTRA-GOLDEN: \(arr.count - bad.count)/\(arr.count) match; mismatches: \(bad)")
        XCTAssertTrue(bad.isEmpty, "mismatches: \(bad)")
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

    // MARK: antialiased resize (PIL bicubic port)
    func testDownscaleOfHighFrequencyPatternAveragesOut() {
        // 1-px checkerboard 768x768 -> 256 (factor 3): an antialiased resize gives ~mid-grey everywhere, while the
        // old bilinear sampled single pixels and aliased (regression guard that FAILS on the pre-fix code).
        let n = 768
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n { for x in 0..<n { let v: UInt8 = (x + y) % 2 == 0 ? 0 : 255; for c in 0..<3 { px[(y * n + x) * 4 + c] = v } } }
        let img = RawImage(width: n, height: n, rgba: px)
        func reds(_ r: RawImage) -> [Int] { stride(from: 0, to: r.rgba.count, by: 4).map { Int(r.rgba[$0]) } }
        let mid = reds(ImagePreprocessing.prepare(img))
        XCTAssertTrue(mid.allSatisfy { abs($0 - 127) <= 4 }, "min \(mid.min()!) max \(mid.max()!)")
        XCTAssertTrue(reds(ml32LegacyBilinear(img)).contains { abs($0 - 127) > 60 }, "legacy bilinear should alias this pattern")
    }

    func testPILTapsAreNormalisedAndIdentityAtSameSize() {
        for t in PILResample.table(inSize: 1000, outSize: 256, outStart: 0, outCount: 256) {
            XCTAssertEqual(Int(t.weights.reduce(0, +)), 1 << PILResample.bits, accuracy: 8)
        }
        let id = PILResample.table(inSize: 10, outSize: 10, outStart: 0, outCount: 10)
        for (i, t) in id.enumerated() { XCTAssertEqual(t.weights[i - t.start], Int32(1 << PILResample.bits)) }
    }

    func testCenterCropAspectMatchesTorchvision() {
        // 300x200 -> short side 256, long side Int(256*300/200)=384, crop offset round((384-256)/2)=64: output is 256x256.
        let img = RawImage(width: 300, height: 200, rgba: [UInt8](repeating: 9, count: 300 * 200 * 4))
        let out = ImagePreprocessing.prepare(img)
        XCTAssertEqual([out.width, out.height], [256, 256])
        XCTAssertTrue(stride(from: 0, to: out.rgba.count, by: 4).allSatisfy { out.rgba[$0] == 9 })
    }

    /// Writes Swift outputs for tools/preproc_reference.py to compare against PIL. Set RECALL_PREPROC_DIR to the
    /// directory produced by `preproc_reference.py make`.
    func testMeasureAgainstPILReference() throws {
        #if canImport(ImageIO)
        guard let dir = ProcessInfo.processInfo.environment["RECALL_PREPROC_DIR"] else {
            throw XCTSkip("RECALL_PREPROC_DIR not set")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }
        XCTAssertFalse(urls.isEmpty)
        for u in urls {
            let name = u.deletingPathExtension().lastPathComponent
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                return XCTFail("cannot decode \(u.path)")
            }
            var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let ctx = CGContext(data: &rgba, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let raw = RawImage(width: cg.width, height: cg.height, rgba: rgba)
            let ref = try Data(contentsOf: u.deletingPathExtension().appendingPathExtension("ref.rgb"))
            func rgb(_ r: RawImage) -> Data { Data(stride(from: 0, to: r.rgba.count, by: 4).flatMap { [r.rgba[$0], r.rgba[$0 + 1], r.rgba[$0 + 2]] }) }
            func mae(_ a: Data, _ b: Data) -> Double { zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count) }
            let new = rgb(ImagePreprocessing.prepare(raw)), old = rgb(ml32LegacyBilinear(raw))
            try new.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).swift_new.rgb"))
            try old.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).swift_old.rgb"))
            print("PREPROC \(name): MAE old(bilinear)=\(String(format: "%.3f", mae(old, ref))) new(PIL port)=\(String(format: "%.3f", mae(new, ref)))")
        }
        #else
        throw XCTSkip("ImageIO unavailable")
        #endif
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

    func testLocatorSearchesBundleRootSubfoldersAndCompilesPackageOnce() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ml32pkg-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let support = base.appendingPathComponent("support")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        // raw packages + tokenizer files in Application Support only
        for n in ["MobileCLIP_S0_Text.mlpackage", "MobileCLIP_S0_Image.mlpackage"] {
            try fm.createDirectory(at: support.appendingPathComponent(n), withIntermediateDirectories: true)
        }
        try Data().write(to: support.appendingPathComponent("vocab.json"))
        try Data().write(to: support.appendingPathComponent("merges.txt"))
        var compiles: [String] = []
        let compiler: (URL) throws -> URL = { pkg in
            compiles.append(pkg.lastPathComponent)
            let out = base.appendingPathComponent("tmp-\(UUID().uuidString).mlmodelc")
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            return out
        }
        let loc = ModelLocator(bundles: [], applicationSupport: support, compiler: compiler)
        let first = try loc.locateAll()
        XCTAssertEqual(first.textModel.lastPathComponent, "MobileCLIP_S0_Text.mlmodelc")
        XCTAssertTrue(first.textModel.path.contains("/Compiled/"))
        XCTAssertEqual(Set(compiles), ["MobileCLIP_S0_Text.mlpackage", "MobileCLIP_S0_Image.mlpackage"])
        _ = try loc.locateAll()
        XCTAssertEqual(compiles.count, 2, "second lookup must reuse the cached compile")

        // a failing compile is reported, and the asset is still listed as missing
        try fm.removeItem(at: support.appendingPathComponent("Compiled"))
        struct Boom: Error {}
        let bad = ModelLocator(bundles: [], applicationSupport: support, compiler: { _ in throw Boom() })
        XCTAssertThrowsError(try bad.locateAll()) { e in
            let err = e as? ModelLocatorError
            XCTAssertEqual(err?.missing, [.textModel, .imageModel])
            XCTAssertEqual(err?.details.count, 2)
        }
    }

    func testLocatorFindsBundleSubfolderRecursively() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ml32bundle-\(UUID().uuidString).bundle")
        defer { try? fm.removeItem(at: base) }
        let res = base.appendingPathComponent("Contents/Resources/Models/deeper", isDirectory: true)
        try fm.createDirectory(at: res.appendingPathComponent("MobileCLIP_S0_Text.mlmodelc"), withIntermediateDirectories: true)
        try Data().write(to: res.appendingPathComponent("vocab.json"))
        try Data().write(to: base.appendingPathComponent("Contents/Resources/merges.txt"))
        try fm.createDirectory(at: base.appendingPathComponent("Contents/Resources/MobileCLIP_S0_Image.mlmodelc"), withIntermediateDirectories: true)
        try "<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>x.y</string></dict></plist>"
            .write(to: base.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        guard let bundle = Bundle(url: base), let root = bundle.resourceURL else { return XCTFail("synthetic bundle did not load") }
        XCTAssertTrue(fm.fileExists(atPath: root.path))
        let loc = ModelLocator(bundles: [bundle], applicationSupport: nil)
        let all = try loc.locateAll()
        XCTAssertTrue(all.textModel.path.hasSuffix("Models/deeper/MobileCLIP_S0_Text.mlmodelc"))
        XCTAssertTrue(all.imageModel.path.hasSuffix("Resources/MobileCLIP_S0_Image.mlmodelc"))
        XCTAssertEqual(all.vocab.lastPathComponent, "vocab.json")
    }

    /// Runs the real Core ML models on this Mac: RECALL_MODELS_DIR holds the converter output (the two .mlpackage
    /// folders, vocab.json, merges.txt) and RECALL_PREPROC_DIR holds dog.png (ml/conversion/data/dog.jpg, which is a photo of a TIGER) (preproc_reference.py make).
    /// Exercises ModelLocator's compile-once path, the validated tokenizer and the real runners end to end.
    func testRealCoreMLModelsRankTigerPhotoAsCatNotDog() throws {
        #if canImport(CoreML) && canImport(ImageIO)
        let env = ProcessInfo.processInfo.environment
        guard let models = env["RECALL_MODELS_DIR"], let pre = env["RECALL_PREPROC_DIR"] else {
            throw XCTSkip("RECALL_MODELS_DIR / RECALL_PREPROC_DIR not set")
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ml32real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        for f in try FileManager.default.contentsOfDirectory(atPath: models) {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: models).appendingPathComponent(f), to: cache.appendingPathComponent(f))
        }
        let enc = try CoreMLEncoderFactory.make(locator: ModelLocator(bundles: [], applicationSupport: cache))
        XCTAssertTrue(enc.text.tokenizer.isValidated)
        func image(_ name: String) throws -> RawImage {
            let u = URL(fileURLWithPath: pre).appendingPathComponent("\(name).png")
            let cg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(u as CFURL, nil)!, 0, nil)!
            var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let ctx = CGContext(data: &rgba, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return RawImage(width: cg.width, height: cg.height, rgba: rgba)
        }
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        let tiger = try enc.image.embedOne(try image("dog"))
        let tDog = try enc.text.encode("a photo of a dog"), tCat = try enc.text.encode("a photo of a cat")
        let tCar = try enc.text.encode("a photo of a car engine")
        print("REALMODEL tiger image: cos(dog)=\(dot(tiger, tDog)) cos(cat)=\(dot(tiger, tCat)) cos(car engine)=\(dot(tiger, tCar))")
        XCTAssertEqual(tiger.count, 512)
        XCTAssertGreaterThan(dot(tiger, tCat), dot(tiger, tDog))
        XCTAssertGreaterThan(dot(tiger, tDog), dot(tiger, tCar))
        XCTAssertEqual(dot(tDog, tDog), 1, accuracy: 1e-3)
        #else
        throw XCTSkip("CoreML/ImageIO unavailable")
        #endif
    }
}

// PR 39 review P1: one MLModel must never be entered by two threads at once. A fake "model" that records overlap.
final class ML39OverlapProbe {
    private let lock = NSLock()
    private var inside = 0
    private(set) var maxInside = 0
    private(set) var calls = 0
    func predict() -> Int {
        lock.lock(); inside += 1; calls += 1; maxInside = max(maxInside, inside); lock.unlock()
        Thread.sleep(forTimeInterval: 0.002)
        lock.lock(); inside -= 1; lock.unlock()
        return 1
    }
}

final class ML39SerialGateTests: XCTestCase {
    private func hammer(_ probe: ML39OverlapProbe, gate: SerialGate?) {
        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<20 { _ = gate.map { $0.run { probe.predict() } } ?? probe.predict() }
            }
        }
        group.wait()
    }

    func testHarnessDetectsOverlapWithoutTheGate() {
        let probe = ML39OverlapProbe()
        hammer(probe, gate: nil)
        XCTAssertGreaterThan(probe.maxInside, 1, "sanity: the probe sees concurrent entry when unserialized")
    }

    func testGateNeverLetsTwoPredictionsOverlap() {
        let probe = ML39OverlapProbe()
        hammer(probe, gate: SerialGate())
        XCTAssertEqual(probe.maxInside, 1)
        XCTAssertEqual(probe.calls, 160)
    }

    func testGatePropagatesErrorsAndReleases() {
        struct Boom: Error {}
        let gate = SerialGate()
        XCTAssertThrowsError(try gate.run { throw Boom() })
        XCTAssertEqual(gate.run { 7 }, 7, "lock released after a throw")
    }
}
