import Foundation

public enum EvalQueryType: String, Codable, Equatable, CaseIterable {
    case exact, attribute, descriptive, ambiguous
}

/// One entry of `evals/queries.yaml`. `targets` has one id, or two for ambiguous queries.
public struct EvalQuery: Equatable {
    public var id: String
    public var text: String
    public var type: EvalQueryType
    public var targets: [String]
    public init(id: String, text: String, type: EvalQueryType, targets: [String]) {
        self.id = id; self.text = text; self.type = type; self.targets = targets
    }
}

public enum EvalQueryError: Error, Equatable {
    case syntax(line: Int, message: String)
    case missingField(queryIndex: Int, field: String)
    case invalidType(queryID: String, value: String)
    case duplicateID(String)
    case emptyTargets(queryID: String)
}

/// Loads `queries.yaml` without a YAML dependency. Supports the fixed shape from
/// docs/03_CONTRACTS.md section 4 (a list of flat mappings; `target_object_id` is a scalar, a
/// `[a, b]` flow list, or a block list) and JSON (which is valid YAML, and is what the repo's
/// placeholder file uses).
public enum EvalQueryLoader {
    public static func load(_ text: String) throws -> [EvalQuery] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") { return try fromJSON(trimmed) }
        return try fromYAML(text)
    }

    public static func load(url: URL) throws -> [EvalQuery] {
        try load(String(contentsOf: url, encoding: .utf8))
    }

    // MARK: JSON

    private static func fromJSON(_ text: String) throws -> [EvalQuery] {
        guard let data = text.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EvalQueryError.syntax(line: 1, message: "expected a JSON array of objects")
        }
        var maps: [[String: [String]]] = []
        for obj in array {
            var m: [String: [String]] = [:]
            for (k, v) in obj {
                if let s = v as? String { m[k] = [s] }
                else if let a = v as? [String] { m[k] = a }
                else { throw EvalQueryError.syntax(line: 1, message: "field \(k) must be a string or list of strings") }
            }
            maps.append(m)
        }
        return try build(maps)
    }

    // MARK: YAML subset

    private static func fromYAML(_ text: String) throws -> [EvalQuery] {
        var maps: [[String: [String]]] = []
        var current: [String: [String]]?
        var listKey: String?
        let lines = text.components(separatedBy: .newlines)
        for (offset, raw) in lines.enumerated() {
            let n = offset + 1
            let line = stripComment(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.trimmingCharacters(in: .whitespaces) == "[]" && maps.isEmpty && current == nil { continue }
            var body = line.trimmingCharacters(in: .whitespaces)
            let indented = line.hasPrefix(" ") || line.hasPrefix("\t")

            if body.hasPrefix("- ") || body == "-" {
                let rest = body.dropFirst().trimmingCharacters(in: .whitespaces)
                if indented, let key = listKey, current != nil {
                    // Block-list item for the previous key.
                    guard !rest.contains(": ") || rest.hasPrefix("\"") || rest.hasPrefix("'") else {
                        throw EvalQueryError.syntax(line: n, message: "unexpected mapping inside list")
                    }
                    current![key, default: []].append(try scalar(rest, line: n))
                    continue
                }
                if let c = current { maps.append(c) }
                current = [:]; listKey = nil
                body = rest
                if body.isEmpty { continue }
            }
            guard current != nil else { throw EvalQueryError.syntax(line: n, message: "expected '- ' to start a query") }
            guard let colon = body.firstIndex(of: ":") else {
                throw EvalQueryError.syntax(line: n, message: "expected 'key: value'")
            }
            let key = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw EvalQueryError.syntax(line: n, message: "empty key") }
            if value.isEmpty {
                listKey = key; current![key] = []
            } else if value.hasPrefix("[") {
                guard value.hasSuffix("]") else { throw EvalQueryError.syntax(line: n, message: "unterminated [ list") }
                let inner = String(value.dropFirst().dropLast())
                current![key] = try splitFlow(inner, line: n).map { try scalar($0, line: n) }
                listKey = nil
            } else {
                current![key] = [try scalar(value, line: n)]
                listKey = nil
            }
        }
        if let c = current { maps.append(c) }
        return try build(maps)
    }

    /// Drop a trailing `# comment` that is outside quotes.
    private static func stripComment(_ s: String) -> String {
        var quote: Character?
        var prev: Character = " "
        for (i, ch) in s.enumerated() {
            if let q = quote { if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "#" && (prev == " " || prev == "\t" || i == 0) {
                return String(s.prefix(i))
            }
            prev = ch
        }
        return s
    }

    private static func splitFlow(_ s: String, line: Int) throws -> [String] {
        var parts: [String] = []
        var cur = ""
        var quote: Character?
        for ch in s {
            if let q = quote { cur.append(ch); if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch; cur.append(ch) }
            else if ch == "," { parts.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        if quote != nil { throw EvalQueryError.syntax(line: line, message: "unterminated quote") }
        parts.append(cur)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func scalar(_ s: String, line: Int) throws -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return "" }
        if first == "\"" || first == "'" {
            guard t.count >= 2, t.last == first else {
                throw EvalQueryError.syntax(line: line, message: "unterminated quote")
            }
            let inner = String(t.dropFirst().dropLast())
            return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                                 : inner.replacingOccurrences(of: "''", with: "'")
        }
        return t
    }

    // MARK: Validation

    private static func build(_ maps: [[String: [String]]]) throws -> [EvalQuery] {
        var seen = Set<String>()
        var out: [EvalQuery] = []
        for (i, m) in maps.enumerated() {
            func one(_ k: String) throws -> String {
                guard let v = m[k]?.first, !v.isEmpty else { throw EvalQueryError.missingField(queryIndex: i, field: k) }
                return v
            }
            let id = try one("id")
            let text = try one("text")
            let typeRaw = try one("type")
            guard let type = EvalQueryType(rawValue: typeRaw) else {
                throw EvalQueryError.invalidType(queryID: id, value: typeRaw)
            }
            guard let targets = m["target_object_id"] else {
                throw EvalQueryError.missingField(queryIndex: i, field: "target_object_id")
            }
            guard !targets.isEmpty, !targets.contains("") else { throw EvalQueryError.emptyTargets(queryID: id) }
            guard seen.insert(id).inserted else { throw EvalQueryError.duplicateID(id) }
            out.append(EvalQuery(id: id, text: text, type: type, targets: targets))
        }
        return out
    }
}
