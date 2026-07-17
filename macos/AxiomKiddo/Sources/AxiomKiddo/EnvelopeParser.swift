import Foundation

// =================================================================
// EnvelopeParser — extract SMTP envelope (From: / To:) from an EML.
//
// The wallet's outbox files are full RFC 5321 emails — header block,
// blank line, body. We only need From: + To: to drive SMTP delivery;
// the rest goes over the wire as-is.
//
// Mirrors `sdk/transports/src/kiddo.rs::parse_envelope` so that
// Kiddo.app's wire behaviour matches the soak-test KIDDO carrier.
// =================================================================

struct Envelope {
    let from: String
    let to: String
}

enum EnvelopeParser {
    static func parse(_ data: Data) -> Envelope? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // Cut at first blank line (header / body separator).
        let headerEnd: String.Index = text.range(of: "\r\n\r\n")?.lowerBound
            ?? text.range(of: "\n\n")?.lowerBound
            ?? text.endIndex
        let headers = String(text[..<headerEnd])

        var from: String?
        var to: String?
        // CRITICAL: do NOT use `split { $0 == "\r" || $0 == "\n" }` here.
        // Swift's String groups CRLF (\r\n) into a SINGLE Character
        // (grapheme cluster), so a per-character closure comparing
        // against "\r" or "\n" individually never matches a CRLF, and
        // every line in the header block collapses into one rawLine —
        // From: and To: parse to whole-header garbage and Envelope
        // returns nil. `components(separatedBy: .newlines)` handles
        // \r, \n, \r\n, and Unicode line separators correctly.
        for rawLine in headers.components(separatedBy: .newlines) {
            let lower = rawLine.lowercased()
            if lower.hasPrefix("from:") {
                let v = rawLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
                from = stripBrackets(v)
            } else if lower.hasPrefix("to:") {
                let v = rawLine.dropFirst(3).trimmingCharacters(in: .whitespaces)
                to = stripBrackets(v)
            }
        }
        guard let f = from, let t = to else { return nil }
        return Envelope(from: f, to: t)
    }

    private static func stripBrackets(_ s: String) -> String {
        var v = s
        if let lt = v.firstIndex(of: "<"), let gt = v.firstIndex(of: ">"), lt < gt {
            v = String(v[v.index(after: lt)..<gt])
        }
        return v.trimmingCharacters(in: .whitespaces)
    }
}
