import Foundation

/// Just enough MIME parsing to show PGP/MIME messages: walks multipart entities and returns the
/// preferred text part (HTML over plain text). Attachments inside the MIME tree are skipped.
enum MIMEParser {
    struct Part {
        var headers: [String: String]
        var body: String

        var contentType: String {
            headers["content-type"]?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        }

        func parameter(_ name: String) -> String? {
            guard let header = headers["content-type"] else { return nil }
            for piece in header.split(separator: ";").dropFirst() {
                let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, pair[0].lowercased() == name {
                    return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            return nil
        }
    }

    static func content(of raw: String) -> MessageContent {
        let root = parse(raw)
        if let html = find("text/html", in: root) { return .html(decode(html)) }
        if let plain = find("text/plain", in: root) { return .plain(decode(plain)) }
        return .plain(root.body)
    }

    static func parse(_ raw: String) -> Part {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let (headerBlock, body): (Substring, Substring)
        if let range = normalized.range(of: "\n\n") {
            headerBlock = normalized[..<range.lowerBound]
            body = normalized[range.upperBound...]
        } else {
            headerBlock = normalized[...]
            body = ""
        }
        return Part(headers: parseHeaders(headerBlock), body: String(body))
    }

    static func parseHeaders(_ block: Substring) -> [String: String] {
        var headers: [String: String] = [:]
        var lastKey: String?
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", let key = lastKey {
                // Folded continuation line.
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                lastKey = key
            }
        }
        return headers
    }

    static func children(of part: Part) -> [Part] {
        guard part.contentType.hasPrefix("multipart/"), let boundary = part.parameter("boundary") else { return [] }
        let delimiter = "--" + boundary
        var sections = part.body.components(separatedBy: delimiter)
        guard sections.count > 1 else { return [] }
        sections.removeFirst() // preamble
        return sections
            .prefix { !$0.hasPrefix("--") } // closing delimiter and epilogue
            .map { section in
                var text = Substring(section)
                if text.hasPrefix("\n") { text = text.dropFirst() }
                if text.hasSuffix("\n") { text = text.dropLast() }
                return parse(String(text))
            }
    }

    static func find(_ type: String, in part: Part) -> Part? {
        if part.contentType == type, !(part.headers["content-disposition"]?.lowercased().hasPrefix("attachment") ?? false) {
            return part
        }
        for child in children(of: part) {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }

    static func decode(_ part: Part) -> String {
        let encoding = part.headers["content-transfer-encoding"]?.lowercased() ?? "7bit"
        let charset = part.parameter("charset")?.lowercased() ?? "utf-8"
        let data: Data
        switch encoding {
        case "base64":
            data = Data(base64Encoded: part.body.filter { !$0.isWhitespace }) ?? Data(part.body.utf8)
        case "quoted-printable":
            data = decodeQuotedPrintable(part.body)
        default:
            return part.body
        }
        let stringEncoding: String.Encoding = (charset == "iso-8859-1" || charset == "latin1") ? .isoLatin1 : .utf8
        return String(data: data, encoding: stringEncoding) ?? String(decoding: data, as: UTF8.self)
    }

    static func decodeQuotedPrintable(_ input: String) -> Data {
        var output = Data()
        let bytes = Array(input.utf8)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "=") {
                if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\n") {
                    i += 2 // soft line break
                    continue
                }
                if i + 2 < bytes.count, let value = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                    output.append(value)
                    i += 3
                    continue
                }
            }
            output.append(byte)
            i += 1
        }
        return output
    }
}
