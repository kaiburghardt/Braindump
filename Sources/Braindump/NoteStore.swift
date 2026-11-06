import Foundation

/// What a note is. Stored as data (in Braindump.json), shown as the icon left of the note.
enum NoteType: String, Codable, Sendable, CaseIterable {
    case note, todo, done, radar

    /// Reads the `type` field; accepts the old name "watch" for radar.
    init(stored: String) {
        switch stored {
        case "todo": self = .todo
        case "done": self = .done
        case "radar", "watch": self = .radar
        default: self = .note
        }
    }

    /// Type for a typed shortcut like `[ ] ` or `🚧 `.
    init?(marker: LineKind) {
        switch marker {
        case .todoMarker: self = .todo
        case .doneMarker: self = .done
        case .radarMarker: self = .radar
        default: return nil
        }
    }

    var isTask: Bool { self == .todo || self == .done }

    /// Label used by the classifier and the "learned" examples.
    var label: String {
        switch self {
        case .todo, .done: "todo"
        case .radar: "radar"
        case .note: "note"
        }
    }
}

/// A note in the editor: a block of a title line and optional detail lines,
/// with a stable ID (kept while typing) and metadata.
struct Note: Identifiable, Equatable {
    let id: String
    let type: NoteType
    let firstLine: NoteLine
    let detailLines: [NoteLine]
    let spaceBefore: Int
    let created: Date
    let lastChecked: Date?
    let link: URL?

    var title: String { firstLine.body }
    var key: String { firstLine.key }
    var lineCount: Int { 1 + detailLines.count }
    var lastLine: NoteLine { detailLines.last ?? firstLine }
    /// Range in the document from the first to the last line (without the final line break).
    var range: NSRange {
        NSRange(location: firstLine.range.location, length: NSMaxRange(lastLine.range) - firstLine.range.location)
    }
    var allLines: [NoteLine] { [firstLine] + detailLines }
}

/// Metadata of a note that is not part of the text.
struct NoteRecord: Equatable {
    var created: Date
    var lastChecked: Date?
    var type: NoteType = .note
}

// MARK: - File format (Braindump.json)

/// One note in the file – meant to be easy to read:
///
///     { "type": "radar", "title": "Launch liveness check", "details": ["https://…"],
///       "created": "…", "lastChecked": "…", "id": "…" }
struct StoredNote: Codable, Equatable {
    var type: String
    var title: String
    var details: [String]?
    /// Blank lines before the note, only when it isn't exactly one (zero for the first note)
    var spaceBefore: Int?
    var created: Date
    var lastChecked: Date?
    var archived: Date?
    var id: String

    var noteType: NoteType { NoteType(stored: type) }

    init(_ note: Note, index: Int, archived: Date? = nil) {
        type = note.type.rawValue
        // The title line is stored as typed (bullets, headings …) – except a leftover shortcut marker.
        title = note.firstLine.kind.isTypeMarker ? note.title : note.firstLine.raw
        details = note.detailLines.isEmpty ? nil : note.detailLines.map(\.raw)
        let defaultSpace = index == 0 ? 0 : 1
        spaceBefore = note.spaceBefore == defaultSpace ? nil : note.spaceBefore
        created = note.created
        lastChecked = note.type == .radar ? note.lastChecked : nil
        self.archived = archived
        id = note.id
    }
}

struct NotesFile: Codable {
    var format = "braindump/1"
    var notes: [StoredNote]

    /// The text as it appears in the editor. Notes are always separated by at least one blank
    /// line – that's what tells them apart once the type markers are gone.
    func render() -> String {
        var lines: [String] = []
        for (index, note) in notes.enumerated() {
            let space = note.spaceBefore ?? (index == 0 ? 0 : 1)
            lines += Array(repeating: "", count: index == 0 ? max(0, space) : max(1, space))
            lines.append(note.title)
            lines += note.details ?? []
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let stringEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// JSON with a fixed, readable key order (type, title, details, …, id).
    /// JSONEncoder doesn't guarantee an order, so this is written by hand.
    func encoded() -> Data {
        func string(_ s: String) -> String {
            (try? Self.stringEncoder.encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        let dates = ISO8601DateFormatter()
        var out = "{\n  \"format\" : \(string(format)),\n  \"notes\" : ["
        for (i, note) in notes.enumerated() {
            var fields = ["\"type\" : \(string(note.type))", "\"title\" : \(string(note.title))"]
            if let details = note.details, !details.isEmpty {
                fields.append("\"details\" : [\n" + details.map { "        \(string($0))" }.joined(separator: ",\n") + "\n      ]")
            }
            if let space = note.spaceBefore { fields.append("\"spaceBefore\" : \(space)") }
            fields.append("\"created\" : \(string(dates.string(from: note.created)))")
            if let checked = note.lastChecked { fields.append("\"lastChecked\" : \(string(dates.string(from: checked)))") }
            if let archived = note.archived { fields.append("\"archived\" : \(string(dates.string(from: archived)))") }
            fields.append("\"id\" : \(string(note.id))")
            out += (i == 0 ? "\n" : ",\n") + "    {\n      " + fields.joined(separator: ",\n      ") + "\n    }"
        }
        out += notes.isEmpty ? "]\n}\n" : "\n  ]\n}\n"
        return Data(out.utf8)
    }
}

// MARK: - App state (Application Support/state.json)

/// What the app remembers that isn't part of the notes.
struct AppState: Codable, Equatable {
    var dismissedSuggestions: [String] = []
    /// What you turned notes into (text → "todo" / "radar" / "note"). The mini model learns from it.
    var learned: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dismissedSuggestions = try c.decodeIfPresent([String].self, forKey: .dismissedSuggestions) ?? []
        let raw = try c.decodeIfPresent([String: String].self, forKey: .learned) ?? [:]
        learned = raw.mapValues { $0 == "watch" ? "radar" : $0 }
    }
}

/// Reads the old plain-text version (Notes.txt + Notes.state.json).
struct LegacyTextImport {
    struct OldState: Decodable {
        struct Watch: Decodable { var added: Date; var lastChecked: Date? }
        var watch: [String: Watch]?
        var dismissedSuggestions: [String]?
        var learned: [String: String]?
    }

    let text: String
    let state: OldState?

    init?(textURL: URL) {
        guard let text = try? String(contentsOf: textURL, encoding: .utf8) else { return nil }
        self.text = text
        let stateURL = textURL.deletingPathExtension().appendingPathExtension("state.json")
        state = (try? Data(contentsOf: stateURL)).flatMap { try? NotesFile.decoder.decode(OldState.self, from: $0) }
    }
}
