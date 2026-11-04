import Foundation


/// A parsed DDC/CI (MCCS) capabilities string, e.g.
/// `(prot(monitor)type(LCD)model(C24G1)cmds(01 02 03)vcp(10 12 14(01 05 06) 60(0F 11 12))mccs_ver(2.2))`.
public struct Capabilities: Equatable, Sendable {
    public let raw: String
    /// Top-level `key(value)` pairs, values kept as raw text.
    public let fields: [String: String]
    /// Supported VCP codes. An empty array means "continuous" (no value list advertised).
    public let vcp: [UInt8: [UInt16]]
    /// VCP codes in the order the monitor listed them.
    public let vcpOrder: [UInt8]

    public var model: String? { fields["model"] }

    /// True when the string looks fully read: parentheses balance and a `vcp(...)` list exists.
    /// A read cut short (bus collision, timeout) almost always leaves a paren open. Only complete
    /// strings may be cached, or a truncated list would hide controls on every launch.
    public var isComplete: Bool {
        var depth = 0
        for ch in raw {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0 && fields["vcp"] != nil && !vcp.isEmpty
    }
    public var mccsVersion: String? { fields["mccs_ver"] }

    public func supports(_ code: UInt8) -> Bool { vcp[code] != nil }

    /// Advertised discrete values for `code` (empty if continuous or unsupported).
    public func values(for code: UInt8) -> [UInt16] { vcp[code] ?? [] }

    public init(parsing raw: String) {
        self.raw = raw
        var body = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        // Strip the single pair of outer parentheses if present.
        if body.first == "(", let close = Capabilities.matchingClose(in: body, open: body.startIndex),
           body.index(after: close) == body.endIndex {
            body = body[body.index(after: body.startIndex)..<close]
        }
        let fields = Capabilities.topLevelFields(body)
        self.fields = fields
        let (map, order) = Capabilities.parseVCP(fields["vcp"] ?? "")
        self.vcp = map
        self.vcpOrder = order
    }

    // MARK: - Parsing helpers

    static func matchingClose(in s: Substring, open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var i = open
        while i < s.endIndex {
            if s[i] == "(" { depth += 1 }
            if s[i] == ")" { depth -= 1; if depth == 0 { return i } }
            i = s.index(after: i)
        }
        return nil
    }

    static func topLevelFields(_ s: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var i = s.startIndex
        while i < s.endIndex {
            // Read a key: run of identifier characters up to "(".
            var keyStart = i
            while i < s.endIndex, s[i] != "(" {
                if !(s[i].isLetter || s[i].isNumber || s[i] == "_") { keyStart = s.index(after: i) }
                i = s.index(after: i)
            }
            guard i < s.endIndex, let close = matchingClose(in: s, open: i) else { break }
            let key = s[keyStart..<i].lowercased()
            let value = String(s[s.index(after: i)..<close])
            if !key.isEmpty, result[key] == nil { result[key] = value }
            i = s.index(after: close)
        }
        return result
    }

    static func parseVCP(_ s: String) -> ([UInt8: [UInt16]], [UInt8]) {
        var map: [UInt8: [UInt16]] = [:]
        var order: [UInt8] = []
        let chars = Array(s)
        var i = 0
        var last: UInt8?
        func hexPair(at j: Int) -> UInt8? {
            guard j + 1 < chars.count, chars[j].isHexDigit, chars[j + 1].isHexDigit else { return nil }
            return UInt8(String(chars[j...j + 1]), radix: 16)
        }
        while i < chars.count {
            let c = chars[i]
            if c == "(", let code = last {
                // Value list for the previous code; may itself contain nested groups we flatten/skip.
                var depth = 1
                var j = i + 1
                var values: [UInt16] = []
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1; j += 1; continue }
                    if chars[j] == ")" { depth -= 1; j += 1; continue }
                    if depth == 1, let v = hexPair(at: j) { values.append(UInt16(v)); j += 2; continue }
                    j += 1
                }
                map[code] = values
                i = j
                last = nil
                continue
            }
            if let code = hexPair(at: i) {
                if map[code] == nil { order.append(code) }
                map[code] = map[code] ?? []
                last = code
                i += 2
                continue
            }
            i += 1
        }
        return (map, order)
    }
}
