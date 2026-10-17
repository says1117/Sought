import Foundation

public enum CLIPTokenizerError: Error, Equatable, CustomStringConvertible {
    case fileMissing(String)
    case malformedVocab(String)
    case malformedMerges(String)
    case missingSpecialTokens

    public var description: String {
        switch self {
        case .fileMissing(let f): return "Tokenizer file missing: \(f)"
        case .malformedVocab(let why): return "vocab.json is not a token-to-id map: \(why)"
        case .malformedMerges(let why): return "merges.txt is malformed: \(why)"
        case .missingSpecialTokens: return "vocab.json has no <start_of_text> / <end_of_text> entries"
        }
    }
}

/// OpenAI CLIP byte-level BPE tokenizer, a port of the spec in ml/conversion/export_tokenizer.py
/// (which matches open_clip exactly on the golden phrases). MobileCLIP-S0 uses the same vocabulary.
/// Output: `[start] + ids.prefix(75) + [end]`, zero-padded to `contextLength` (77).
///
/// Not ported: ftfy.fix_text and html.unescape (typed or speech English is unaffected).
/// Symbols missing from the loaded vocab are dropped instead of crashing; the real 49,408-entry vocab
/// covers every byte so this only matters for hand-made test vocabularies.
///
/// Vocabulary files are NOT committed. Produce them with `ml/conversion/export_tokenizer.py`
/// (writes `build/tokenizer/vocab.json` and `merges.txt`); see ml/conversion/README.md.
public struct CLIPTokenizer {
    public static let contextLength = 77
    public static let vocabFileName = "vocab.json"
    public static let mergesFileName = "merges.txt"
    public static let padID: Int32 = 0

    public let startID: Int32
    public let endID: Int32
    private let vocab: [String: Int]
    private let ranks: [String: Int]   // "left right" -> rank (line index)
    private let byteToUnicode: [UInt8: String]
    private static let pattern: NSRegularExpression = {
        // Same as open_clip, lowercase input; \p{N} is ONE digit per token.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<start_of_text>|<end_of_text>|'s|'t|'re|'ve|'m|'ll|'d|\p{L}+|\p{N}|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive])
    }()

    public init(vocab: [String: Int], merges: [(String, String)]) throws {
        guard let s = vocab["<start_of_text>"], let e = vocab["<end_of_text>"] else {
            throw CLIPTokenizerError.missingSpecialTokens
        }
        self.vocab = vocab
        self.startID = Int32(s)
        self.endID = Int32(e)
        var r: [String: Int] = [:]
        r.reserveCapacity(merges.count)
        for (i, m) in merges.enumerated() where r["\(m.0) \(m.1)"] == nil { r["\(m.0) \(m.1)"] = i }
        self.ranks = r
        self.byteToUnicode = CLIPTokenizer.makeByteToUnicode()
    }

    /// Loads `vocab.json` and `merges.txt` from a directory.
    public init(directory: URL) throws {
        let vocabURL = directory.appendingPathComponent(Self.vocabFileName)
        let mergesURL = directory.appendingPathComponent(Self.mergesFileName)
        try self.init(vocabURL: vocabURL, mergesURL: mergesURL)
    }

    public init(vocabURL: URL, mergesURL: URL) throws {
        guard let vdata = try? Data(contentsOf: vocabURL) else { throw CLIPTokenizerError.fileMissing(vocabURL.path) }
        guard let mdata = try? Data(contentsOf: mergesURL) else { throw CLIPTokenizerError.fileMissing(mergesURL.path) }
        let vocab: [String: Int]
        do { vocab = try JSONDecoder().decode([String: Int].self, from: vdata) }
        catch { throw CLIPTokenizerError.malformedVocab("\(error)") }
        guard let text = String(data: mdata, encoding: .utf8) else { throw CLIPTokenizerError.malformedMerges("not UTF-8") }
        var merges: [(String, String)] = []
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { throw CLIPTokenizerError.malformedMerges("line \(n + 1): \(line)") }
            merges.append((String(parts[0]), String(parts[1])))
        }
        try self.init(vocab: vocab, merges: merges)
    }

    /// Loads the files from a bundle's resources (root or any subdirectory).
    public init(bundle: Bundle) throws {
        guard let v = bundle.url(forResource: "vocab", withExtension: "json") else {
            throw CLIPTokenizerError.fileMissing(Self.vocabFileName)
        }
        guard let m = bundle.url(forResource: "merges", withExtension: "txt") else {
            throw CLIPTokenizerError.fileMissing(Self.mergesFileName)
        }
        try self.init(vocabURL: v, mergesURL: m)
    }

    /// Token ids padded/truncated to `contextLength`.
    public func encode(_ text: String) -> [Int32] {
        let clean = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        var ids: [Int32] = []
        let ns = clean as NSString
        let matches = Self.pattern.matches(in: clean, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let piece = ns.substring(with: m.range)
            if piece == "<start_of_text>" { ids.append(startID); continue }
            if piece == "<end_of_text>" { ids.append(endID); continue }
            let mapped = piece.utf8.map { byteToUnicode[$0] ?? "" }
            for sym in bpe(mapped) { if let id = vocab[sym] { ids.append(Int32(id)) } }
        }
        let body = ids.prefix(Self.contextLength - 2)
        var out = [startID] + body + [endID]
        out += [Int32](repeating: Self.padID, count: Self.contextLength - out.count)
        return out
    }

    func bpe(_ chars: [String]) -> [String] {
        guard !chars.isEmpty else { return [] }
        var word = chars
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, pair: (String, String))?
            for i in 0..<(word.count - 1) {
                if let r = ranks["\(word[i]) \(word[i + 1])"], r < (best?.rank ?? Int.max) {
                    best = (r, (word[i], word[i + 1]))
                }
            }
            guard let b = best else { break }
            var next: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == b.pair.0, word[i + 1] == b.pair.1 {
                    next.append(word[i] + word[i + 1]); i += 2
                } else { next.append(word[i]); i += 1 }
            }
            word = next
        }
        return word
    }

    /// GPT-2 byte -> printable unicode map (same construction as export_tokenizer.bytes_to_unicode).
    public static func makeByteToUnicode() -> [UInt8: String] {
        var bs: [Int] = Array(0x21...0x7E) + Array(0xA1...0xAC) + Array(0xAE...0xFF)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
        var map: [UInt8: String] = [:]
        for (b, c) in zip(bs, cs) { map[UInt8(b)] = String(UnicodeScalar(UInt32(c))!) }
        return map
    }
}
