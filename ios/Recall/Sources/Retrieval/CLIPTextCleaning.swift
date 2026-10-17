import Foundation

/// Swift stand-in for open_clip's `whitespace_clean(basic_clean(text))` front end. open_clip runs
/// `ftfy.fix_text`, then `html.unescape` twice, then collapses whitespace. There is no ftfy in Swift, so this
/// ports the parts that change token ids for typed or dictated English:
///   - HTML entity unescape, applied twice (numeric entities plus the common named ones, see `namedEntities`)
///   - mojibake repair for the UTF-8-read-as-Latin-1 pattern ("cafÃ©" -> "café")
///   - Latin ligature expansion (ﬁ ﬂ ﬀ ﬃ ﬄ ﬅ ﬆ Ĳ ĳ)
///   - full-width ASCII to ASCII (ｆｕｌｌ -> full), as ftfy's fix_character_width
///   - curly quotes to straight quotes (ftfy uncurl_quotes; iOS smart punctuation produces "it’s")
///   - removal of NUL and other C0/C1 control characters (ftfy remove_control_chars)
///   - Unicode NFC normalization
/// Not ported: ftfy's cp1252 mojibake variants (e.g. "â€™"), its other heuristics, and the full 2,231-name HTML5
/// entity table. Verified against open_clip on the cases above (see MLEncodersTests).
public enum CLIPTextCleaning {
    public static func clean(_ text: String) -> String {
        var s = unescapeHTML(unescapeHTML(text))   // ftfy unescapes once on non-HTML text; open_clip unescapes twice more
        s = fixMojibake(s)
        s = fixCharacters(s)
        s = s.precomposedStringWithCanonicalMapping
        return s
    }

    // MARK: characters

    private static let ligatures: [Unicode.Scalar: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi", "\u{FB04}": "ffl",
        "\u{FB05}": "\u{17F}t", "\u{FB06}": "st", "\u{0132}": "IJ", "\u{0133}": "ij",
    ]

    private static let curly: [Unicode.Scalar: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
        "\u{2039}": "'", "\u{203A}": "'", "\u{00AB}": "\"", "\u{00BB}": "\"",
    ]

    private static func fixCharacters(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let v = u.value
            if v == 0 || (v < 0x20 && v != 9 && v != 10 && v != 13) || (v >= 0x7F && v <= 0x9F && v != 0x85) { continue }
            if let l = ligatures[u] { out.append(contentsOf: l.unicodeScalars); continue }
            if let c = curly[u] { out.append(contentsOf: c.unicodeScalars); continue }
            if v >= 0xFF01 && v <= 0xFF5E { out.append(Unicode.Scalar(v - 0xFEE0)!); continue }   // full-width ASCII
            if v == 0x3000 { out.append(" "); continue }
            out.append(u)
        }
        return String(out)
    }

    // MARK: mojibake

    /// Re-decodes runs where UTF-8 bytes were shown as Latin-1 characters: a lead scalar U+00C2...U+00F4 followed by
    /// the right number of U+0080...U+00BF scalars that together form valid UTF-8.
    static func fixMojibake(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        guard scalars.contains(where: { $0.value >= 0xC2 && $0.value <= 0xF4 }) else { return s }
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            let need = v >= 0xF0 && v <= 0xF4 ? 3 : v >= 0xE0 && v <= 0xEF ? 2 : v >= 0xC2 && v <= 0xDF ? 1 : 0
            if need > 0, i + need < scalars.count,
               (1...need).allSatisfy({ scalars[i + $0].value >= 0x80 && scalars[i + $0].value <= 0xBF }) {
                let bytes = (0...need).map { UInt8(scalars[i + $0].value) }
                if let d = String(bytes: bytes, encoding: .utf8) {
                    out.append(contentsOf: d.unicodeScalars); i += need + 1; continue
                }
            }
            out.append(scalars[i]); i += 1
        }
        return String(out)
    }

    // MARK: HTML entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "copy": "©", "reg": "®",
        "deg": "°", "plusmn": "±", "frac12": "½", "frac14": "¼", "frac34": "¾", "times": "×", "divide": "÷",
        "cent": "¢", "pound": "£", "yen": "¥", "euro": "€", "sect": "§", "para": "¶", "middot": "·",
        "hellip": "…", "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "trade": "™", "bull": "•",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "aacute": "á", "agrave": "à", "acirc": "â",
        "auml": "ä", "aring": "å", "atilde": "ã", "ccedil": "ç", "iacute": "í", "igrave": "ì", "icirc": "î",
        "iuml": "ï", "ntilde": "ñ", "oacute": "ó", "ograve": "ò", "ocirc": "ô", "ouml": "ö", "otilde": "õ",
        "uacute": "ú", "ugrave": "ù", "ucirc": "û", "uuml": "ü", "yacute": "ý", "szlig": "ß",
        "Eacute": "É", "Agrave": "À", "Aacute": "Á", "Ouml": "Ö", "Uuml": "Ü", "Auml": "Ä", "Ntilde": "Ñ",
    ]
    /// Python's html.unescape also accepts these legacy names without the trailing semicolon.
    private static let legacyNoSemicolon: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

    static func unescapeHTML(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "&" else { out.append(chars[i]); i += 1; continue }
            var j = i + 1
            while j < chars.count, j - i <= 32, chars[j] != ";", chars[j] != "&", !chars[j].isWhitespace { j += 1 }
            let hasSemi = j < chars.count && chars[j] == ";"
            let body = String(chars[(i + 1)..<min(j, chars.count)])
            if hasSemi, let r = decodeEntity(body) { out += r; i = j + 1; continue }
            // legacy: "&amp" with no semicolon, optionally followed by other text
            if !hasSemi || decodeEntity(body) == nil {
                var matched = false
                for name in legacyNoSemicolon.sorted(by: { $0.count > $1.count }) where body.hasPrefix(name) {
                    out += namedEntities[name]!; i += 1 + name.count; matched = true; break
                }
                if matched { continue }
            }
            out.append("&"); i += 1
        }
        return out
    }

    private static func decodeEntity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") { value = UInt32(digits.dropFirst(), radix: 16) }
            else { value = UInt32(digits, radix: 10) }
            guard let v = value else { return nil }
            if v == 0 || v > 0x10FFFF || (0xD800...0xDFFF).contains(v) { return "\u{FFFD}" }
            return Unicode.Scalar(v).map { String($0) }
        }
        return namedEntities[body]
    }
}
