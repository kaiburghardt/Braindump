import Foundation

/// What a single line of editor text is.
///
/// A note's type (to-do, radar …) is stored as data, not in the text. The editor text only
/// carries a few light conventions: `# heading`, `- bullet`, links. Typed shortcuts at the start
/// of a line (`[ ] `, `[x] `, `🚧 `) are still recognized so they can be turned into a note type
/// and removed from the text.
enum LineKind: Equatable, Sendable {
    case blank, plain, bullet, heading, link
    /// Typed shortcuts – converted into a note type right after typing.
    case todoMarker, doneMarker, radarMarker

    var isTypeMarker: Bool { self == .todoMarker || self == .doneMarker || self == .radarMarker }
}

struct LineInfo: Equatable, Sendable {
    var kind: LineKind
    /// UTF-16 offset inside the line where the marker starts (after indentation).
    var markerStart: Int = 0
    /// UTF-16 length of the marker including trailing spaces.
    var markerLength: Int = 0
    var bodyStart: Int { markerStart + markerLength }
}

struct NoteLine: Identifiable, Equatable {
    /// 0-based line number.
    let index: Int
    /// Range of the line in the document (without the line break), UTF-16.
    let range: NSRange
    let raw: String
    let info: LineInfo
    /// Text without marker, trimmed.
    let body: String
    /// Normalized text used to recognize the line again.
    let key: String
    /// Link in this line or in a link-only line directly below.
    var link: URL?

    var id: Int { index }
    var kind: LineKind { info.kind }
    var markerRange: NSRange {
        NSRange(location: range.location + info.markerStart, length: info.markerLength)
    }
}

enum NoteParser {
    static let radarScalar: Unicode.Scalar = "\u{1F6A7}" // 🚧 (legacy marker)

    static func classify(_ line: String) -> LineInfo {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let ws = indent.utf16.count
        let rest = line[indent.endIndex...]
        if rest.allSatisfy(\.isWhitespace) { return LineInfo(kind: .blank, markerStart: ws) }

        func spaces(_ s: Substring) -> Int { s.prefix { $0 == " " || $0 == "\t" }.utf16.count }

        // Typed to-do shortcuts: "[ ] …", "[x] …", optionally as a Markdown list "- [ ] …"
        var box = rest
        var listPrefix = 0
        if rest.hasPrefix("- [") || rest.hasPrefix("* [") {
            box = rest.dropFirst(2)
            listPrefix = 2
        }
        for (pattern, kind) in [("[ ]", LineKind.todoMarker), ("[x]", .doneMarker), ("[X]", .doneMarker)] where box.hasPrefix(pattern) {
            let after = box.dropFirst(3)
            if after.isEmpty || after.first == " " || after.first == "\t" {
                return LineInfo(kind: kind, markerStart: ws, markerLength: listPrefix + 3 + spaces(after))
            }
        }

        // Typed radar shortcut: 🚧
        if let first = rest.first, first.unicodeScalars.first == radarScalar {
            return LineInfo(kind: .radarMarker, markerStart: ws, markerLength: first.utf16.count + spaces(rest.dropFirst()))
        }

        // Heading: "# …"
        let hashes = rest.prefix { $0 == "#" }.count
        if (1...3).contains(hashes), rest.dropFirst(hashes).first == " " {
            return LineInfo(kind: .heading, markerStart: ws, markerLength: hashes + spaces(rest.dropFirst(hashes)))
        }

        // Bullet: "- …", "* …", "• …"
        if let first = rest.first, "-*•".contains(first), rest.dropFirst().first == " " {
            return LineInfo(kind: .bullet, markerStart: ws, markerLength: first.utf16.count + spaces(rest.dropFirst()))
        }

        // Link-only line
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")), !trimmed.contains(" ") {
            return LineInfo(kind: .link, markerStart: ws)
        }
        return LineInfo(kind: .plain, markerStart: ws)
    }

    static func parse(_ text: String) -> [NoteLine] {
        let ns = text as NSString
        var result: [NoteLine] = []
        var location = 0
        while location < ns.length {
            var end = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let range = NSRange(location: location, length: contentsEnd - location)
            let raw = ns.substring(with: range)
            let info = classify(raw)
            let rawNS = raw as NSString
            let body = rawNS.substring(from: min(info.bodyStart, rawNS.length)).trimmingCharacters(in: .whitespaces)
            result.append(NoteLine(index: result.count, range: range, raw: raw, info: info, body: body, key: key(body), link: nil))
            if end <= location { break }
            location = end
        }

        // Attach links: in the line itself or a link-only line directly below
        for i in result.indices where result[i].kind != .blank && result[i].kind != .link {
            if let url = firstURL(in: result[i].body) {
                result[i].link = url
            } else if i + 1 < result.count, result[i + 1].kind == .link {
                result[i].link = URL(string: result[i + 1].body)
            }
        }
        return result
    }

    static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Links

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// Only web and mail links become clickable – no file:// or app URL schemes from note text.
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func urlRanges(in text: String) -> [(range: NSRange, url: URL)] {
        guard text.contains("http") || text.contains("www."), let detector else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, allowedSchemes.contains(url.scheme?.lowercased() ?? "") else { return nil }
            return (match.range, url)
        }
    }

    static func firstURL(in text: String) -> URL? {
        urlRanges(in: text).first?.url
    }
}

// MARK: - Notes as blocks

/// A note = a block of consecutive lines. A blank line ends a note. A heading (and a freshly
/// typed shortcut like `[ ] `) always starts its own note. All other lines are details of the
/// note above.
struct NoteBlock: Equatable {
    /// Indices into `lines`
    let lineIndices: ClosedRange<Int>
    /// Blank lines directly before the block
    let spaceBefore: Int

    var first: Int { lineIndices.lowerBound }
    var last: Int { lineIndices.upperBound }
    var lineCount: Int { lineIndices.count }
}

extension NoteParser {
    static func blocks(from lines: [NoteLine]) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        var start: Int?
        var end = 0
        var spaceBefore = 0
        var blanks = 0
        func close() {
            if let s = start { blocks.append(NoteBlock(lineIndices: s...end, spaceBefore: spaceBefore)) }
            start = nil
        }
        for line in lines {
            if line.kind == .blank {
                close()
                blanks += 1
                continue
            }
            if start == nil || startsOwnNote(line.kind) {
                close()
                start = line.index
                spaceBefore = blanks
                blanks = 0
            }
            end = line.index
        }
        close()
        return blocks
    }

    static func startsOwnNote(_ kind: LineKind) -> Bool {
        kind == .heading || kind.isTypeMarker
    }
}
