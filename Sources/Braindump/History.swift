import Foundation
import Observation

/// A short-term version history of the notes – separate from ⌘Z and from the daily backups.
///
/// Snapshots are plain copies of the notes file (same JSON as Braindump.json), one file each in
/// `~/Library/Application Support/Braindump/History/<notes file>/`. The model takes one after a
/// pause in typing, and keeps the state right before text gets deleted – so something you wrote
/// and then deleted can be found again. A snapshot is removed once it's older than the retention
/// time *and* not among the newest `minimumEntries` – so a quiet day still leaves a long history,
/// and a busy one keeps everything from the retention time.
@MainActor
@Observable
final class HistoryStore {
    struct Entry: Identifiable, Hashable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    /// Newest first.
    private(set) var entries: [Entry] = []

    var retentionHours: Int {
        didSet {
            UserDefaults.standard.set(retentionHours, forKey: Self.retentionKey)
            prune()
        }
    }

    static let retentionKey = "historyHours"
    static let retentionChoices = [1, 24, 24 * 7]

    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var lastData: Data?
    @ObservationIgnored private var cache: [URL: NotesFile] = [:]
    /// Kept even when they're older than the retention time. A snapshot is a full copy of the notes
    /// file, so this is about 1000 × its size on disk.
    static let minimumEntries = 1000

    private static let nameFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return f
    }()

    init() {
        UserDefaults.standard.register(defaults: [Self.retentionKey: 24])
        retentionHours = max(1, UserDefaults.standard.integer(forKey: Self.retentionKey))
    }

    /// One history per notes file.
    func open(for notesFile: URL, defaultFile: URL, supportFolder: URL) {
        let name = notesFile == defaultFile
            ? notesFile.deletingPathExtension().lastPathComponent
            : "\(notesFile.deletingPathExtension().lastPathComponent)-\(Self.stableHash(notesFile.path))"
        let folder = supportFolder.appending(path: "History/\(name)", directoryHint: .isDirectory)
        guard folder != self.folder else { return }
        self.folder = folder
        cache = [:]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        entries = files.compactMap { url in
            guard url.pathExtension == "json",
                  let date = Self.nameFormat.date(from: url.deletingPathExtension().lastPathComponent) else { return nil }
            return Entry(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
        lastData = entries.first.flatMap { try? Data(contentsOf: $0.url) }
        prune()
    }

    /// Saves a snapshot – unless it's the same as the newest one.
    func record(_ file: NotesFile, at date: Date = Date()) {
        guard let folder else { return }
        let data = file.encoded()
        guard data != lastData else { return }
        // Keep the list sorted even if an older state (taken before a deletion) comes in late.
        var stamp = date
        if let newest = entries.first?.date, stamp <= newest { stamp = newest.addingTimeInterval(0.001) }
        let url = folder.appending(path: Self.nameFormat.string(from: stamp) + ".json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        lastData = data
        cache[url] = file
        entries.insert(Entry(url: url, date: stamp), at: 0)
        prune()
    }

    func file(for entry: Entry) -> NotesFile? {
        if let cached = cache[entry.url] { return cached }
        guard let data = try? Data(contentsOf: entry.url),
              let file = try? NotesFile.decoder.decode(NotesFile.self, from: data) else { return nil }
        cache[entry.url] = file
        return file
    }

    /// The version before an entry (nil for the oldest one).
    func previous(of entry: Entry) -> Entry? {
        guard let index = entries.firstIndex(of: entry), index + 1 < entries.count else { return nil }
        return entries[index + 1]
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(retentionHours) * 3600)
        let expired = entries.dropFirst(Self.minimumEntries).filter { $0.date < cutoff }
        guard !expired.isEmpty else { return }
        for entry in expired {
            try? FileManager.default.removeItem(at: entry.url)
            cache[entry.url] = nil
        }
        let gone = Set(expired)
        entries.removeAll { gone.contains($0) }
    }

    /// FNV-1a – Swift's `hashValue` changes with every launch.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }
}

// MARK: - What changed between two versions

/// The change of one note between two versions, matched by its ID.
struct NoteChange: Identifiable {
    enum Kind { case added, removed, edited }

    let id: String
    let kind: Kind
    let old: StoredNote?
    let new: StoredNote?
    /// For removed notes: the ID of the note that came before it (to put it back in the same place).
    let previousID: String?

    var note: StoredNote { (new ?? old)! }
    var typeChanged: Bool { old != nil && new != nil && old!.noteType != new!.noteType }
    var textChanged: Bool { old.map(\.lines) != new.map(\.lines) }

    /// Line by line: unchanged, removed and added lines in reading order.
    var lineDiff: [DiffLine] {
        let before = old?.lines ?? []
        let after = new?.lines ?? []
        var result: [DiffLine] = []
        var removed: [Int: String] = [:]
        var inserted: [Int: String] = [:]
        for change in after.difference(from: before) {
            switch change {
            case let .remove(offset, line, _): removed[offset] = line
            case let .insert(offset, line, _): inserted[offset] = line
            }
        }
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed[i] != nil {
                result.append(DiffLine(kind: .removed, text: before[i])); i += 1
            } else if j < after.count, inserted[j] != nil {
                result.append(DiffLine(kind: .added, text: after[j])); j += 1
            } else {
                if j < after.count { result.append(DiffLine(kind: .same, text: after[j])) }
                i += 1; j += 1
            }
        }
        return result
    }

    static func between(_ old: NotesFile?, _ new: NotesFile) -> [NoteChange] {
        let oldNotes = old?.notes ?? []
        let oldByID = Dictionary(oldNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.notes.map(\.id))
        var changes: [(order: Double, change: NoteChange)] = []
        var newIndex: [String: Int] = [:]
        for (index, note) in new.notes.enumerated() {
            newIndex[note.id] = index
            if let before = oldByID[note.id] {
                let change = NoteChange(id: note.id, kind: .edited, old: before, new: note, previousID: nil)
                if change.textChanged || change.typeChanged { changes.append((Double(index), change)) }
            } else {
                changes.append((Double(index), NoteChange(id: note.id, kind: .added, old: nil, new: note, previousID: nil)))
            }
        }
        // Removed notes go where they were: right after the last surviving note before them.
        var lastSurvivor: String?
        var offset = 0.0
        for note in oldNotes {
            if newIDs.contains(note.id) {
                lastSurvivor = note.id
                offset = 0
                continue
            }
            offset += 0.01
            let order = (lastSurvivor.flatMap { newIndex[$0] }.map(Double.init) ?? -1) + 0.5 + offset
            changes.append((order, NoteChange(id: note.id, kind: .removed, old: note, new: nil, previousID: lastSurvivor)))
        }
        return changes.sorted { $0.order < $1.order }.map(\.change)
    }
}

struct DiffLine: Hashable {
    enum Kind { case same, added, removed }
    let kind: Kind
    let text: String
}

extension StoredNote {
    var lines: [String] { [title] + (details ?? []) }
}
