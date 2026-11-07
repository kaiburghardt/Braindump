import AppKit
import Observation
import UniformTypeIdentifiers

/// The editor shows plain text; on disk the notes live in readable JSON
/// (`~/Documents/Braindump/Braindump.json`): a list of notes with type, title, details and metadata.
/// A note is a block of consecutive lines; its type (to-do, radar …) is data, shown as the icon
/// left of the note – not as characters in the text.
///
/// The model holds the editor text, derives the notes from it (with stable IDs), saves
/// automatically (shortly after typing, when switching apps, on quit) and notices external edits.
@MainActor
@Observable
final class NotesModel {
    static let shared = NotesModel()

    enum SaveStatus: Equatable {
        case saved
        case failed(String)
    }

    typealias Edit = (range: NSRange, text: String)

    private enum Keys {
        static let path = "notesPath"
        static let interval = "checkIntervalDays"
        static let fontSize = "fontSize"
        static let fontFamily = "fontFamily"
        static let ai = "aiEnabled"
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Braindump/Braindump.json")
    }

    /// ~/Library/Application Support/Braindump (backups, mini model, link cache, app state).
    /// Test runs with `-notesPath …` get their own folder.
    static var supportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: isTestRun ? "Braindump-Test" : "Braindump", directoryHint: .isDirectory)
    }

    static var isTestRun: Bool {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[Keys.path] != nil
    }

    // MARK: Settings

    var checkIntervalDays: Int {
        didSet { UserDefaults.standard.set(checkIntervalDays, forKey: Keys.interval); updateBadge() }
    }
    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }
    var fontFamily: String {
        didSet { UserDefaults.standard.set(fontFamily, forKey: Keys.fontFamily) }
    }
    var editorFont: EditorFont { EditorFont(family: fontFamily, size: CGFloat(fontSize)) }
    var aiEnabled: Bool {
        didSet {
            UserDefaults.standard.set(aiEnabled, forKey: Keys.ai)
            recomputeSuggestions()
            if aiEnabled { scheduleAnalysis(after: .milliseconds(100)) }
        }
    }

    // MARK: State

    private(set) var fileURL: URL
    private(set) var text = ""
    private(set) var lines: [NoteLine] = []
    private(set) var notes: [Note] = []
    private(set) var openTodos: [Note] = []
    private(set) var doneTodos: [Note] = []
    private(set) var radarItems: [RadarItem] = []
    private(set) var suggestions: [Suggestion] = []
    private(set) var saveStatus: SaveStatus = .saved
    private(set) var now = Date()
    /// Type of the note the cursor is in (nil on a blank line) – for the toolbar buttons.
    private(set) var cursorNoteType: NoteType?
    /// Short message about the last AI action, shown over the editor for a few seconds.
    private(set) var aiNotice: String?
    /// The Ask sheet (⌘K).
    var askPresented = false

    let engine = SuggestionEngine()
    let links = LinkPreviewService()
    let ai = AIService()
    let history = HistoryStore()

    @ObservationIgnored weak var textView: NoteTextView?
    @ObservationIgnored private var appState = AppState()
    @ObservationIgnored private var appStateDirty = false
    @ObservationIgnored private var records: [String: NoteRecord] = [:]
    /// Notes of the previous pass (ID + key, in order) – keeps IDs stable while typing.
    @ObservationIgnored private var matchPool: [(id: String, key: String)] = []
    /// Notes that disappeared recently (e.g. so ⌘Z after deleting gets the same note back).
    @ObservationIgnored private var orphans: [(id: String, key: String)] = []
    @ObservationIgnored private var noteByStart: [Int: Note] = [:]
    /// Types for notes that are about to appear (typed shortcuts like `[ ] `), by title key.
    @ObservationIgnored private var pendingTypes: [String: NoteType] = [:]
    /// An empty line that becomes a note of this type as soon as you type on it (next to-do after ↩).
    @ObservationIgnored private var pendingNewNote: (location: Int, type: NoteType)?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var lastSavedData: Data?
    @ObservationIgnored private var lastModDate: Date?
    @ObservationIgnored private var legacyImportURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    @ObservationIgnored private var retrainTask: Task<Void, Never>?
    @ObservationIgnored private var lastEditLocation: Int?
    @ObservationIgnored private var isProgrammaticEdit = false
    // History: states waiting to be written, and the state before the current run of deletions
    @ObservationIgnored private var pendingHistory: [(date: Date, file: NotesFile)] = []
    @ObservationIgnored private var deletionRun: (date: Date, file: NotesFile, deleted: Int, kept: Bool)?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var lastHistoryCapture = Date.distantPast
    /// Notes waiting for an AI answer – their icon pulses.
    @ObservationIgnored private var aiBusy: Set<String> = []
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    private var appStateURL: URL { Self.supportURL.appending(path: "state.json") }
    private var archiveURL: URL {
        fileURL.deletingLastPathComponent().appending(path: fileURL.deletingPathExtension().lastPathComponent + "-Archive.json")
    }

    private init() {
        Self.migrateFromWriteNotes()
        let d = UserDefaults.standard
        d.register(defaults: [Keys.interval: 4, Keys.fontSize: 14.0, Keys.fontFamily: EditorFont.defaultFamily, Keys.ai: true])
        checkIntervalDays = max(1, d.integer(forKey: Keys.interval))
        fontSize = d.double(forKey: Keys.fontSize)
        let family = d.string(forKey: Keys.fontFamily) ?? EditorFont.defaultFamily
        fontFamily = EditorFont.isAvailable(family) ? family : EditorFont.defaultFamily
        aiEnabled = d.bool(forKey: Keys.ai)
        var url = Self.defaultURL
        if let path = d.string(forKey: Keys.path), !path.isEmpty {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if url.pathExtension.lowercased() == "txt" {
            // An old setting points to a text file → create a JSON file next to it and import.
            legacyImportURL = url
            url = url.deletingPathExtension().appendingPathExtension("json")
        }
        fileURL = url

        engine.ai = ai
        ai.onChange = { [weak self] in
            self?.engine.refreshAvailability()
            self?.textView?.scheduleIconRefresh()
        }
        engine.onResults = { [weak self] in self?.recomputeSuggestions() }
        engine.onBackendChange = { [weak self] in
            self?.recomputeSuggestions()
            self?.scheduleAnalysis(after: .milliseconds(300))
        }
        links.onChange = { [weak self] in self?.textView?.needsDisplay = true }
        links.onCredentialsChange = { [weak self] in self?.scheduleLinkRefresh(force: true) }
        engine.refreshAvailability()
        load()
        engine.prepareClassifier(examples: trainingExamples())
        startBackgroundLoop()
        observeAppLifecycle()
        SelfTest.runIfRequested(model: self)
        SelfTest.runAIProbeIfRequested(model: self)
        RenderTest.runIfRequested(model: self)
    }

    /// One-time: take over data, backups and settings of the old "WriteNotes" version.
    private static func migrateFromWriteNotes() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromWriteNotes") else { return }
        guard !isTestRun else { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let oldSupport = supportURL.deletingLastPathComponent().appending(path: "WriteNotes")
        try? fm.createDirectory(at: supportURL, withIntermediateDirectories: true)
        let moves = [
            (home.appending(path: "Documents/WriteNotes"), defaultURL.deletingLastPathComponent()),
            (oldSupport.appending(path: "Backups"), supportURL.appending(path: "Backups")),
        ]
        for (old, new) in moves where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }
        if (try? fm.contentsOfDirectory(atPath: oldSupport.path))?.isEmpty == true {
            try? fm.removeItem(at: oldSupport)
        }
        if let old = UserDefaults(suiteName: "local.kai.WriteNotes") {
            for key in [Keys.interval, Keys.fontSize, Keys.ai, "showInspector", "showDoneTodos"]
            where d.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { d.set(value, forKey: key) }
            }
            if let path = old.string(forKey: Keys.path), !path.contains("/Documents/WriteNotes/") {
                d.set(path, forKey: Keys.path)
            }
        }
        d.set(true, forKey: "migratedFromWriteNotes")
    }

    // MARK: - Loading & saving

    func load() {
        loaded = false
        appState = loadAppState()
        let fm = FileManager.default
        do {
            let folder = fileURL.deletingLastPathComponent()
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Earlier versions used a German folder name for the imported text file.
            let oldFolder = folder.appending(path: "Alte Textversion")
            let newFolder = folder.appending(path: "Old text version")
            if fm.fileExists(atPath: oldFolder.path), !fm.fileExists(atPath: newFolder.path) {
                try? fm.moveItem(at: oldFolder, to: newFolder)
            }
            if !fm.fileExists(atPath: fileURL.path) {
                try createInitialFile()
            }
            let data = try Data(contentsOf: fileURL)
            let file = try NotesFile.decoder.decode(NotesFile.self, from: data)
            adopt(file)
            lastSavedData = data
            lastModDate = Self.modificationDate(of: fileURL)
            loaded = true
            saveStatus = .saved
        } catch {
            text = ""
            saveStatus = .failed("Can't open “\(fileURL.lastPathComponent)”: \(error.localizedDescription)")
        }
        setEditorText(text)
        recompute()
        restyleAll()
        if loaded {
            saveNow() // only writes if something got normalized while reading
            makeDailyBackup()
            history.open(for: fileURL, defaultFile: Self.defaultURL, supportFolder: Self.supportURL)
            captureHistory()
        }
        scheduleAnalysis(after: .milliseconds(400))
    }

    /// Takes over notes from a file: text, metadata and IDs.
    private func adopt(_ file: NotesFile) {
        for note in file.notes {
            records[note.id] = NoteRecord(created: note.created, lastChecked: note.lastChecked, type: note.noteType)
        }
        matchPool = file.notes.map { ($0.id, NoteParser.parse($0.title).first?.key ?? "") }
        orphans = []
        pendingTypes = [:]
        pendingNewNote = nil
        text = file.render()
    }

    /// First launch: import the old text file (Notes.txt) – or start with the welcome note.
    private func createInitialFile() throws {
        let folder = fileURL.deletingLastPathComponent()
        let defaultLegacy = folder.appending(path: "Notes.txt")
        let source = legacyImportURL ?? defaultLegacy
        let legacy = LegacyTextImport(textURL: source)
        let content = legacy?.text ?? Seed.text

        let parsed = NoteParser.parse(content)
        let blocks = NoteParser.blocks(from: parsed)
        let start = Date()
        let stored = blocks.enumerated().map { index, block in
            let first = parsed[block.first]
            let old = legacy?.state?.watch?[first.key]
            let type = NoteType(marker: first.kind) ?? .note
            let record = NoteRecord(created: old?.added ?? start, lastChecked: old?.lastChecked, type: type)
            return StoredNote(Self.makeNote(id: UUID().uuidString, block: block, lines: parsed, record: record), index: index)
        }
        try NotesFile(notes: stored).encoded().write(to: fileURL, options: .atomic)

        if let old = legacy?.state {
            appState.dismissedSuggestions += old.dismissedSuggestions ?? []
            appState.learned.merge((old.learned ?? [:]).mapValues { $0 == "watch" ? "radar" : $0 }) { current, _ in current }
            appStateDirty = true
        }
        // Move our own old text version out of the way so nobody keeps writing into it.
        if legacy != nil, source == defaultLegacy {
            let fm = FileManager.default
            let archive = folder.appending(path: "Old text version", directoryHint: .isDirectory)
            try? fm.createDirectory(at: archive, withIntermediateDirectories: true)
            for name in ["Notes.txt", "Notes.state.json", "Notes.archive.txt"] {
                let old = folder.appending(path: name)
                if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: archive.appending(path: name)) }
            }
        }
        legacyImportURL = nil
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard loaded else { return } // never overwrite a file we couldn't read
        let data = currentFile().encoded()
        if data != lastSavedData {
            do {
                try data.write(to: fileURL, options: .atomic)
                lastSavedData = data
                lastModDate = Self.modificationDate(of: fileURL)
                if saveStatus != .saved { saveStatus = .saved }
                scheduleHistoryCapture()
            } catch {
                saveStatus = .failed("Saving failed: \(error.localizedDescription)")
            }
        }
        if appStateDirty {
            saveAppState()
        }
    }

    /// The notes as they'd be written to the file.
    func currentFile() -> NotesFile {
        NotesFile(notes: notes.enumerated().map { StoredNote($0.element, index: $0.offset) })
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func loadAppState() -> AppState {
        guard let data = try? Data(contentsOf: appStateURL) else { return AppState() }
        return (try? NotesFile.decoder.decode(AppState.self, from: data)) ?? AppState()
    }

    private func saveAppState() {
        try? FileManager.default.createDirectory(at: Self.supportURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if (try? encoder.encode(appState).write(to: appStateURL, options: .atomic)) != nil {
            appStateDirty = false
        }
    }

    /// Once a day a copy goes to ~/Library/Application Support/Braindump/Backups (last 30 kept).
    private func makeDailyBackup() {
        guard loaded, !Self.isTestRun, let data = lastSavedData else { return }
        let fm = FileManager.default
        let dir = Self.supportURL.appending(path: "Backups", directoryHint: .isDirectory)
        let stamp = Date().formatted(.iso8601.year().month().day())
        let name = fileURL == Self.defaultURL
            ? fileURL.deletingPathExtension().lastPathComponent
            : "\(fileURL.deletingLastPathComponent().lastPathComponent)-\(fileURL.deletingPathExtension().lastPathComponent)"
        let target = dir.appending(path: "\(name)-\(stamp).json")
        guard !fm.fileExists(atPath: target.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ ["txt", "json"].contains($0.pathExtension) })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }), files.count > 30 {
            for file in files.dropFirst(30) { try? fm.removeItem(at: file) }
        }
    }

    // MARK: - Switching files

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.message = "Choose a Braindump file (.json) – or a text file to import."
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switchFile(to: url)
    }

    func switchFile(to url: URL) {
        saveNow()
        var target = url
        if url.pathExtension.lowercased() == "txt" {
            legacyImportURL = url
            target = url.deletingPathExtension().appendingPathExtension("json")
        }
        fileURL = target
        UserDefaults.standard.set(target == Self.defaultURL ? nil : target.path, forKey: Keys.path)
        records = [:]
        load()
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - Editor connection

    func attach(_ textView: NoteTextView) {
        self.textView = textView
        textView.noteSpanAt = { [weak self] index in self?.noteSpan(at: index) }
        textView.onGutterClick = { [weak self] index in self?.gutterClick(at: index) }
        textView.gutterMenuItems = { [weak self] index in self?.gutterMenuItems(at: index) ?? [] }
        textView.previewFor = { [weak self] url in self?.links.preview(for: url) }
        textView.onPreviewClick = { [weak self] url in self?.openPreview(url) }
        textView.selectionActions = { [weak self] range in self?.selectionActions(for: range) ?? [] }
        textView.isAIBusyAt = { [weak self] index in self?.isAIBusy(at: index) ?? false }
        setEditorText(text)
        restyleAll()
    }

    private func noteSpan(at index: Int) -> (type: NoteType, lastLine: NSRange, lineCount: Int)? {
        if let note = noteByStart[index] {
            return (note.type, note.lastLine.range, note.lineCount)
        }
        if let pending = pendingNewNote, pending.location == index, line(containing: index)?.kind == .blank || index == (text as NSString).length {
            return (pending.type, NSRange(location: index, length: 0), 1)
        }
        return nil
    }

    /// Opens a link preview: the link itself – or the settings when the connection is missing.
    private func openPreview(_ url: URL) {
        if let preview = links.preview(for: url), preview.needsSetup {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows the Jira/Notion title instead of a bare URL.
    func displayTitle(for note: Note) -> String {
        if note.title.hasPrefix("http"), let url = note.link, let preview = links.preview(for: url), !preview.title.isEmpty {
            return preview.title
        }
        return note.title.isEmpty ? "–" : note.title
    }

    func editorDidChange(_ newText: String, editLocation: Int?) {
        guard newText != text else { return }
        let undoing = textView?.undoManager.map { $0.isUndoing || $0.isRedoing } ?? false
        keepStateBeforeDeletion(old: text, new: newText) // `notes` still describe the old text here
        text = newText
        lastEditLocation = isProgrammaticEdit ? nil : editLocation
        // Typing anywhere else than on the pending "next to-do" line drops it.
        if !isProgrammaticEdit, let pending = pendingNewNote, let edit = editLocation {
            let ns = newText as NSString
            let lineStart = ns.lineRange(for: NSRange(location: min(edit, ns.length), length: 0)).location
            if lineStart != pending.location { pendingNewNote = nil }
        }
        recompute()
        restyleAfterTyping()
        if !undoing && !isProgrammaticEdit { scheduleMarkerConversion() }
        scheduleSave()
        scheduleAnalysis()
    }

    /// When the cursor leaves the line that was just typed in, that line may be analyzed.
    func selectionDidChange(to location: Int) {
        updateCursorNoteType(at: location)
        guard let edit = lastEditLocation, line(containing: location)?.index != line(containing: edit)?.index else { return }
        lastEditLocation = nil
        scheduleAnalysis(after: .milliseconds(500))
    }

    private func setEditorText(_ newText: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        tv.isEditable = loaded
        guard tv.string != newText else { return }
        let selection = tv.selectedRange()
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
        storage.endEditing()
        tv.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
        tv.undoManager?.removeAllActions()
    }

    // MARK: - Deriving notes, to-dos, radar, suggestions

    private func recompute() {
        let parsed = NoteParser.parse(text)
        lines = parsed
        let blocks = NoteParser.blocks(from: parsed)
        let keys = blocks.map { parsed[$0.first].key }
        let ids = assignIDs(keys)

        var result: [Note] = []
        var byStart: [Int: Note] = [:]
        for (block, id) in zip(blocks, ids) {
            let first = parsed[block.first]
            var record = records[id] ?? NoteRecord(created: Date())
            if let pending = pendingNewNote, pending.location == first.range.location, records[id] == nil {
                record.type = pending.type
                pendingNewNote = nil
            }
            if let type = pendingTypes.removeValue(forKey: first.key) {
                record.type = type
            }
            records[id] = record
            let note = Self.makeNote(id: id, block: block, lines: parsed, record: record)
            result.append(note)
            byStart[note.firstLine.range.location] = note
        }

        let current = Set(ids)
        var seen = Set<String>()
        orphans = (matchPool + orphans)
            .filter { !current.contains($0.id) && seen.insert($0.id).inserted }
            .prefix(200)
            .map { $0 }
        matchPool = Array(zip(ids, keys)).map { (id: $0.0, key: $0.1) }

        notes = result
        noteByStart = byStart
        openTodos = result.filter { $0.type == .todo && !$0.title.isEmpty }
        doneTodos = result.filter { $0.type == .done }
        radarItems = result.filter { $0.type == .radar && !$0.key.isEmpty }.map(RadarItem.init(note:))
        recomputeSuggestions()
        updateBadge()
        scheduleLinkRefresh()
        textView?.scheduleIconRefresh()
        updateCursorNoteType()
    }

    private func updateCursorNoteType(at location: Int? = nil) {
        guard let location = location ?? textView?.selectedRange().location else { return }
        let type = line(containing: location).flatMap { $0.kind == .blank ? nil : note(containingLine: $0.index)?.type }
        if type != cursorNoteType { cursorNoteType = type }
    }

    /// Maps the blocks to the IDs of the previous pass: same title first, then a similar title
    /// (typing/rephrasing), then the same slot between unchanged neighbours (title rewritten
    /// completely), otherwise a new ID.
    private func assignIDs(_ keys: [String]) -> [String] {
        var result = [String?](repeating: nil, count: keys.count)
        var used = Set<String>()
        var byKey: [String: [String]] = [:]
        for candidate in matchPool + orphans where !candidate.key.isEmpty {
            byKey[candidate.key, default: []].append(candidate.id)
        }
        for (i, key) in keys.enumerated() where !key.isEmpty {
            while let id = byKey[key]?.first {
                byKey[key]?.removeFirst()
                if used.insert(id).inserted {
                    result[i] = id
                    break
                }
            }
        }
        for i in keys.indices where result[i] == nil {
            var best: (id: String, score: Double, distance: Int)?
            for (j, candidate) in matchPool.enumerated() where !used.contains(candidate.id) {
                let score = TextSimilarity.score(candidate.key, keys[i])
                guard score >= 0.5 else { continue }
                let distance = abs(j - i)
                if best == nil || score > best!.score || (score == best!.score && distance < best!.distance) {
                    best = (candidate.id, score, distance)
                }
            }
            if let best {
                result[i] = best.id
                used.insert(best.id)
            }
        }
        // Same slot: the previous note right after the previous match of my left neighbour.
        let poolIndex = Dictionary(matchPool.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for i in keys.indices where result[i] == nil {
            let slot: Int? = i == 0 ? 0 : result[i - 1].flatMap { poolIndex[$0] }.map { $0 + 1 }
            if let slot, matchPool.indices.contains(slot), !used.contains(matchPool[slot].id),
               i + 1 >= keys.count || result[i + 1] == nil || poolIndex[result[i + 1]!] == slot + 1 {
                result[i] = matchPool[slot].id
                used.insert(matchPool[slot].id)
            }
        }
        return result.map { $0 ?? UUID().uuidString }
    }

    private static func makeNote(id: String, block: NoteBlock, lines: [NoteLine], record: NoteRecord) -> Note {
        let first = lines[block.first]
        let details = block.first < block.last ? Array(lines[(block.first + 1)...block.last]) : []
        let link = ([first] + details).lazy.compactMap { $0.link ?? NoteParser.firstURL(in: $0.raw) }.first
        return Note(id: id, type: record.type, firstLine: first, detailLines: details, spaceBefore: block.spaceBefore,
                    created: record.created, lastChecked: record.lastChecked, link: link)
    }

    private func scheduleLinkRefresh(force: Bool = false) {
        linkTask?.cancel()
        linkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            let urls = self.lines.flatMap { NoteParser.urlRanges(in: $0.raw).map(\.url) }
            self.links.refresh(urls, force: force)
        }
    }

    // MARK: - Typed shortcuts ("[ ] ", "[x] ", "🚧 ")

    private func scheduleMarkerConversion() {
        guard lines.contains(where: { $0.kind.isTypeMarker }) else { return }
        DispatchQueue.main.async { [weak self] in self?.convertTypedMarkers() }
    }

    /// Turns a typed shortcut at the start of a line into the note type and removes it from the
    /// text. A shortcut on a detail line splits that line off into its own note.
    private func convertTypedMarkers() {
        var edits: [Edit] = []
        for line in lines where line.kind.isTypeMarker {
            guard let type = NoteType(marker: line.kind) else { continue }
            let marker = (line.raw as NSString).substring(with: NSRange(location: line.info.markerStart, length: line.info.markerLength))
            guard marker.last == " " || marker.last == "\t" else { continue } // wait for the space after the marker
            let prefix = NSRange(location: line.range.location, length: line.info.bodyStart)
            let isDetail = line.index > 0 && lines[line.index - 1].kind != .blank
            edits.append((prefix, isDetail ? "\n" : ""))
            if line.body.isEmpty {
                pendingNewNote = (line.range.location + (isDetail ? 1 : 0), type)
            } else {
                pendingTypes[line.key] = type
            }
            learn(line.body, as: type.label)
        }
        performEdits(edits, actionName: "Change Type")
        textView?.scheduleIconRefresh()
    }

    // MARK: - Learning

    /// Remembers what you turned a note into – the mini model learns from it.
    private func learn(_ text: String, as label: String) {
        let body = text.trimmingCharacters(in: .whitespaces)
        guard body.count >= 4, !body.hasPrefix("http") else { return }
        appState.learned[body] = label
        if appState.learned.count > 1000, let oldest = appState.learned.keys.first { appState.learned.removeValue(forKey: oldest) }
        appStateDirty = true
        scheduleSave()
        retrainTask?.cancel()
        retrainTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self else { return }
            self.engine.prepareClassifier(examples: self.trainingExamples())
        }
    }

    /// Up to 8 of your own decisions per label, as examples for the AI server's prompt: what you
    /// turned notes into (to-dos and radar items in the file, plus learned clicks and dismissals).
    private func promptExamples() -> [(text: String, label: String)] {
        var own: [String: String] = [:]
        for note in notes where note.title.count >= 6 && !note.title.hasPrefix("http") && note.type != .note {
            own[note.title] = note.type.label
        }
        own.merge(appState.learned) { _, learned in learned }
        var result: [(text: String, label: String)] = []
        for label in ["todo", "radar", "note"] {
            let texts = own.filter { $0.value == label && $0.key.count >= 6 }.keys.sorted()
            result += texts.prefix(8).map { (text: $0, label: label) }
        }
        return result
    }

    /// Base examples + what you marked yourself (your labels count three times).
    private func trainingExamples() -> [LineExample] {
        var examples = LineExample.bundled()
        var own: [String: String] = [:]
        for note in notes where note.title.count >= 4 && !note.title.hasPrefix("http") && note.type != .note {
            own[note.title] = note.type.label
        }
        own.merge(appState.learned) { _, learned in learned }
        for (text, label) in own.sorted(by: { $0.key < $1.key }) {
            examples += Array(repeating: LineExample(text: text, label: label), count: 3)
        }
        return examples
    }

    func recomputeSuggestions() {
        guard aiEnabled else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        let dismissed = Set(appState.dismissedSuggestions)
        var seen = Set<String>()
        var result: [Suggestion] = []
        for note in notes where note.type == .note {
            guard !note.key.isEmpty, !dismissed.contains(note.key), seen.insert(note.key).inserted else { continue }
            switch engine.verdicts[note.key] {
            case .todo: result.append(Suggestion(note: note, type: .todo))
            case .radar: result.append(Suggestion(note: note, type: .radar))
            default: break
            }
        }
        if result != suggestions { suggestions = result }
    }

    func scheduleAnalysis(after delay: Duration = .milliseconds(1500)) {
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.enqueueCandidates()
        }
    }

    func reanalyzeAll() {
        engine.reset()
        recomputeSuggestions()
        scheduleAnalysis(after: .zero)
    }

    private func enqueueCandidates() {
        guard aiEnabled, loaded else { return }
        let dismissed = Set(appState.dismissedSuggestions)
        let activeKey = activeLineKey()
        var seen = Set<String>()
        var items: [ClassifyCandidate] = []
        for note in notes where note.type == .note {
            guard note.title.count >= 6, note.key != activeKey, !dismissed.contains(note.key),
                  engine.verdicts[note.key] == nil, seen.insert(note.key).inserted else { continue }
            items.append(ClassifyCandidate(key: note.key, text: note.title, details: note.detailLines.prefix(2).map(\.body)))
        }
        guard !items.isEmpty else { return }
        if engine.backend == .server { engine.examples = promptExamples() }
        engine.enqueue(items)
    }

    /// The line currently being typed in is only analyzed once the cursor leaves it.
    private func activeLineKey() -> String? {
        guard let tv = textView, let edit = lastEditLocation,
              let cursorLine = line(containing: tv.selectedRange().location),
              cursorLine.index == line(containing: edit)?.index else { return nil }
        return cursorLine.key
    }

    private func line(containing location: Int) -> NoteLine? {
        line(in: lines, containing: location)
    }

    private func line(in lines: [NoteLine], containing location: Int) -> NoteLine? {
        lines.first { $0.range.location <= location && location <= NSMaxRange($0.range) }
    }

    private func note(containingLine index: Int) -> Note? {
        notes.first { $0.firstLine.index <= index && index <= $0.lastLine.index }
    }

    private func updateBadge() {
        let due = radarItems.filter { $0.status(now: now, interval: checkIntervalDays) != .fresh }.count
        NSApplication.shared.dockTile.badgeLabel = due > 0 ? "\(due)" : nil
    }

    // MARK: - Radar

    func markChecked(_ item: RadarItem) {
        records[item.id, default: NoteRecord(created: item.added, type: .radar)].lastChecked = Date()
        now = Date()
        recompute()
        saveNow()
    }

    func resetCheck(_ item: RadarItem) {
        records[item.id]?.lastChecked = nil
        recompute()
        saveNow()
    }

    // MARK: - Changing note types

    /// Click on the icon left of a note.
    /// - to-do ⇄ done: toggled right away (it's a checkbox),
    /// - plain note: menu "To-Do / Radar",
    /// - radar: menu "Checked Today / Make It a To-Do / Take Off the Radar".
    /// Returns the menu items, or nil when the click was handled directly.
    func gutterClick(at index: Int) -> [GutterMenuItem]? {
        if let pending = pendingNewNote, pending.location == index, noteByStart[index] == nil {
            pendingNewNote = nil // click on the empty next to-do → drop it
            textView?.scheduleIconRefresh()
            return nil
        }
        guard let note = noteByStart[index] else { return nil }
        switch note.type {
        case .todo:
            setType(.done, for: [note])
            return nil
        case .done:
            setType(.todo, for: [note])
            return nil
        case .note:
            return [
                GutterMenuItem(title: "To-Do", symbol: "circle") { [weak self] in self?.setType(.todo, for: [note]) },
                GutterMenuItem(title: "Radar – keep an eye on it", symbol: "scope") { [weak self] in self?.setType(.radar, for: [note]) },
            ]
        case .radar:
            var items: [GutterMenuItem] = []
            if let item = radarItems.first(where: { $0.id == note.id }) {
                items.append(GutterMenuItem(title: "Checked Today", symbol: "checkmark") { [weak self] in self?.markChecked(item) })
            }
            items.append(GutterMenuItem(title: "Make It a To-Do", symbol: "circle", separatorBefore: !items.isEmpty) { [weak self] in self?.setType(.todo, for: [note]) })
            items.append(GutterMenuItem(title: "Take Off the Radar", symbol: "xmark.circle") { [weak self] in self?.setType(.note, for: [note]) })
            return items
        }
    }

    /// Right-click on the icon: all types to choose from.
    func gutterMenuItems(at index: Int) -> [GutterMenuItem] {
        guard let note = noteByStart[index] else { return [] }
        var items: [GutterMenuItem] = [
            GutterMenuItem(title: "Note", symbol: "circle.dashed", checked: note.type == .note) { [weak self] in self?.setType(.note, for: [note]) },
            GutterMenuItem(title: "To-Do", symbol: "circle", checked: note.type == .todo) { [weak self] in self?.setType(.todo, for: [note]) },
            GutterMenuItem(title: "Done", symbol: "checkmark.circle.fill", checked: note.type == .done) { [weak self] in self?.setType(.done, for: [note]) },
            GutterMenuItem(title: "Radar – keep an eye on it", symbol: "scope", checked: note.type == .radar) { [weak self] in self?.setType(.radar, for: [note]) },
        ]
        if note.type == .radar, let item = radarItems.first(where: { $0.id == note.id }) {
            items.append(GutterMenuItem(title: "Checked Today", symbol: "checkmark", separatorBefore: true) { [weak self] in self?.markChecked(item) })
        }
        if ai.isConfigured {
            items.append(GutterMenuItem(title: "Tidy Up", symbol: "sparkles", separatorBefore: true) { [weak self] in self?.tidyUp(note) })
            items.append(GutterMenuItem(title: "Extract To-Dos", symbol: "list.bullet.indent") { [weak self] in
                self?.extract(from: note.range, after: note)
            })
        }
        return items
    }

    func toggleDone(_ note: Note) {
        setType(note.type == .done ? .todo : .done, for: [note])
    }

    /// Sets the type of notes. Undoable with ⌘Z.
    func setType(_ type: NoteType, for notes: [Note]) {
        let changes = notes.filter { $0.type != type }
        guard !changes.isEmpty else { return }
        applyTypes(Dictionary(uniqueKeysWithValues: changes.map { ($0.id, type) }), actionName: "Change Type")
        if type != .done {
            for note in changes { learn(note.title, as: type.label) }
        }
    }

    private func applyTypes(_ types: [String: NoteType], actionName: String) {
        var previous: [String: NoteType] = [:]
        for (id, type) in types {
            previous[id] = records[id]?.type ?? .note
            records[id, default: NoteRecord(created: Date())].type = type
        }
        if let tv = textView, let undo = tv.undoManager {
            // Close NSTextView's open typing group first – otherwise one ⌘Z would undo the
            // type change *and* the text typed just before it.
            tv.breakUndoCoalescing()
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.applyTypes(previous, actionName: actionName) }
            }
            undo.setActionName(actionName)
            undo.endUndoGrouping()
        }
        recompute()
        restyle(notes.filter { types[$0.id] != nil })
        scheduleSave()
    }

    func apply(_ suggestion: Suggestion, as type: NoteType) {
        setType(type, for: [suggestion.note])
    }

    func dismiss(_ suggestion: Suggestion) {
        appState.dismissedSuggestions.append(suggestion.note.key)
        if appState.dismissedSuggestions.count > 500 { appState.dismissedSuggestions.removeFirst(100) }
        appStateDirty = true
        recomputeSuggestions()
        learn(suggestion.note.title, as: "note")
    }

    /// ⌘↩: note → to-do → done → to-do …
    func toggleTodoAtSelection() {
        let targets = notesAtSelection()
        guard !targets.isEmpty else { return }
        let next: NoteType = targets.allSatisfy { $0.type == .todo } ? .done : .todo
        setType(next, for: targets)
    }

    /// ⇧⌘↩: radar on/off
    func toggleRadarAtSelection() {
        let targets = notesAtSelection()
        guard !targets.isEmpty else { return }
        setType(targets.allSatisfy { $0.type == .radar } ? .note : .radar, for: targets)
    }

    /// ⌥⌘↩: back to a plain note
    func clearTypeAtSelection() {
        setType(.note, for: notesAtSelection())
    }

    private func notesAtSelection() -> [Note] {
        guard let tv = textView else { return [] }
        return notesTouched(by: linesInSelection(tv.selectedRange()).filter { $0.kind != .blank })
    }

    // MARK: - AI actions (Tidy Up, Extract To-Dos)
    //
    // The request runs in the background; the note's icon pulses meanwhile. The answer is only
    // applied if the note's text is still exactly what was sent – otherwise nothing is replaced.
    // Edits go through `performEdits`, so one ⌘Z undoes them.

    func isAIBusy(at index: Int) -> Bool {
        noteByStart[index].map { aiBusy.contains($0.id) } ?? false
    }

    /// ⌃⌘T: the note at the cursor, or every note in the selection (at most 10).
    func tidyUpAtSelection() {
        for note in notesAtSelection().prefix(10) { tidyUp(note) }
    }

    /// Turns a dictated or rambling note into a short title plus detail lines (same language,
    /// same facts and links).
    func tidyUp(_ note: Note) {
        guard ai.isConfigured else { showAINotice(AIService.Failure.notConfigured.message); return }
        guard !note.title.isEmpty, aiBusy.insert(note.id).inserted else { return }
        let id = note.id
        let type = note.type
        let original = Self.text(of: note)
        textView?.scheduleIconRefresh()
        Task {
            defer { finishAI(id) }
            do throws(AIService.Failure) {
                let tidied = try await AIActions.tidy(original, ai: ai)
                let replacement = AIActions.render(title: tidied.title, details: tidied.details)
                guard let current = notes.first(where: { $0.id == id }), Self.text(of: current) == original else {
                    showAINotice("The note changed while the AI was working – nothing was replaced.")
                    return
                }
                guard !AIActions.cleanTitle(tidied.title).isEmpty, replacement != original else {
                    showAINotice("Nothing to tidy up.")
                    return
                }
                guard AIActions.missingURLs(original: original, result: replacement).isEmpty else {
                    showAINotice("Tidy Up left out a link, so nothing was changed.")
                    return
                }
                // The note keeps its ID (and type) through the edit; this is a safety net.
                pendingTypes[NoteParser.key(AIActions.cleanTitle(tidied.title))] = type
                performEdits([(current.range, replacement)], actionName: "Tidy Up")
            } catch {
                showAINotice(error.message)
            }
        }
    }

    /// ⌃⌘E: the selected text – or the note at the cursor – becomes separate notes below it.
    func extractAtSelection() {
        guard let tv = textView, let last = notesAtSelection().last else { return }
        let selection = tv.selectedRange()
        extract(from: selection.length > 0 ? selection : last.range, after: last)
    }

    /// Asks the AI for the to-dos, radar items and notes in a piece of text and inserts them as
    /// separate notes after `anchor`. The source text stays as it is.
    func extract(from source: NSRange, after anchor: Note) {
        guard ai.isConfigured else { showAINotice(AIService.Failure.notConfigured.message); return }
        let ns = text as NSString
        guard NSMaxRange(source) <= ns.length else { return }
        let original = ns.substring(with: source)
        guard original.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3, aiBusy.insert(anchor.id).inserted else { return }
        let anchorID = anchor.id
        textView?.scheduleIconRefresh()
        Task {
            defer { finishAI(anchorID) }
            do throws(AIService.Failure) {
                let result = try await AIActions.extract(original, today: Date(), ai: ai)
                guard let anchorNow = notes.first(where: { $0.id == anchorID }),
                      (text as NSString).range(of: original).location != NSNotFound else {
                    showAINotice("The text changed while the AI was working – nothing was added.")
                    return
                }
                var blocks: [String] = []
                for item in result.items.prefix(15) {
                    let title = AIActions.cleanTitle(item.title)
                    guard !title.isEmpty else { continue }
                    blocks.append(AIActions.render(title: title, details: item.details))
                    switch item.type {
                    case "todo": pendingTypes[NoteParser.key(title)] = .todo
                    case "radar": pendingTypes[NoteParser.key(title)] = .radar
                    default: break
                    }
                }
                guard !blocks.isEmpty else {
                    showAINotice("No to-dos found in this text.")
                    return
                }
                let location = NSMaxRange(anchorNow.range)
                performEdits([(NSRange(location: location, length: 0), "\n\n" + blocks.joined(separator: "\n\n"))],
                             actionName: "Extract To-Dos")
                if let tv = textView {
                    let first = NSRange(location: min(location + 2, (tv.string as NSString).length), length: 0)
                    tv.setSelectedRange(first)
                    tv.scrollRangeToVisible(first)
                }
                showAINotice("Added \(blocks.count) \(blocks.count == 1 ? "note" : "notes") below.")
            } catch {
                showAINotice(error.message)
            }
        }
    }

    func showAINotice(_ message: String) {
        aiNotice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.aiNotice = nil
        }
    }

    func dismissAINotice() {
        noticeTask?.cancel()
        aiNotice = nil
    }

    private func finishAI(_ id: String) {
        aiBusy.remove(id)
        textView?.scheduleIconRefresh()
    }

    /// The note's text exactly as in the editor (all its lines).
    private static func text(of note: Note) -> String {
        note.allLines.map(\.raw).joined(separator: "\n")
    }

    // MARK: - Several lines: merge & split

    /// What the pop-up above a multi-line selection offers.
    func selectionActions(for selection: NSRange) -> [SelectionAction] {
        let selected = linesInSelection(selection).filter { $0.kind != .blank }
        guard selected.count >= 2 else { return [] }
        let touched = notesTouched(by: selected)
        var actions: [SelectionAction] = []
        if touched.count >= 2 {
            actions.append(SelectionAction(title: "Merge into One Note", systemImage: "arrow.triangle.merge", prominent: true) { [weak self] in
                self?.merge(touched)
            })
        } else if let note = touched.first {
            let detailLines = selected.filter { $0.index != note.firstLine.index }
            if !detailLines.isEmpty {
                actions.append(SelectionAction(title: "Split into Separate Notes", systemImage: "scissors") { [weak self] in
                    self?.split(detailLines)
                })
            }
        }
        actions.append(SelectionAction(title: "To-Do", systemImage: "checkmark.circle") { [weak self] in
            self?.setType(.todo, for: touched)
        })
        actions.append(SelectionAction(title: "Radar", systemImage: "scope") { [weak self] in
            self?.setType(.radar, for: touched)
        })
        if ai.isConfigured {
            actions.append(SelectionAction(title: "Tidy Up", systemImage: "sparkles") { [weak self] in
                self?.tidyUpAtSelection()
            })
            actions.append(SelectionAction(title: "Extract To-Dos", systemImage: "list.bullet.indent") { [weak self] in
                self?.extractAtSelection()
            })
        }
        return actions
    }

    func mergeSelection() {
        merge(notesAtSelection())
    }

    func splitSelection() {
        guard let tv = textView else { return }
        let selected = linesInSelection(tv.selectedRange()).filter { $0.kind != .blank }
        split(selected.filter { line in note(containingLine: line.index)?.firstLine.index != line.index })
    }

    private func notesTouched(by lines: [NoteLine]) -> [Note] {
        var seen = Set<String>()
        return lines.compactMap { note(containingLine: $0.index) }.filter { seen.insert($0.id).inserted }
    }

    /// Merges notes into one: the first one keeps its type, the others become detail lines,
    /// blank lines in between disappear.
    func merge(_ notes: [Note]) {
        guard notes.count >= 2, let first = notes.first, let last = notes.last, let tv = textView else { return }
        let output = notes.flatMap { $0.allLines.map(\.raw) }
        let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let merged = output.joined(separator: "\n")
        performEdits([(range, merged)], actionName: "Merge Notes")
        tv.setSelectedRange(NSRange(location: range.location + (merged as NSString).length, length: 0))
    }

    /// Turns the given detail lines into notes of their own (blank line before each).
    func split(_ lines: [NoteLine]) {
        let edits: [Edit] = lines.compactMap { resolve($0) }.map { (NSRange(location: $0.range.location, length: 0), "\n") }
        performEdits(edits, actionName: "Split Note")
    }

    /// ↩ at the end of a one-line to-do starts the next to-do below (shown as an empty checkbox).
    /// ↩ on that empty line ends the list.
    func handleReturn(in tv: NSTextView) -> Bool {
        let selection = tv.selectedRange()
        guard selection.length == 0 else { return false }
        if let pending = pendingNewNote, pending.location == selection.location,
           line(containing: selection.location)?.kind == .blank || selection.location == (text as NSString).length {
            pendingNewNote = nil
            textView?.scheduleIconRefresh()
            return true
        }
        guard let cursorLine = line(containing: selection.location),
              let note = note(containingLine: cursorLine.index), note.type.isTask, note.detailLines.isEmpty,
              cursorLine.index == note.firstLine.index, selection.location == NSMaxRange(cursorLine.range),
              !cursorLine.body.isEmpty else { return false }
        tv.insertText("\n\n", replacementRange: selection)
        pendingNewNote = (selection.location + 2, .todo)
        textView?.scheduleIconRefresh()
        return true
    }

    /// Moves done to-dos into the archive file (…-Archive.json) next to your notes.
    func archiveDone() {
        let done = doneTodos
        guard loaded, !done.isEmpty else { return }
        let stamp = Date()
        var archive = (try? Data(contentsOf: archiveURL)).flatMap { try? NotesFile.decoder.decode(NotesFile.self, from: $0) }
            ?? NotesFile(format: "braindump-archive/1", notes: [])
        archive.notes += done.map { StoredNote($0, index: 1, archived: stamp) }
        do {
            try archive.encoded().write(to: archiveURL, options: .atomic)
        } catch {
            saveStatus = .failed("Archiving failed: \(error.localizedDescription)")
            return
        }
        let ns = text as NSString
        performEdits(done.map { (ns.lineRange(for: $0.range), "") }, actionName: "Archive Done")
        saveNow()
    }

    // MARK: - Styling by type (done = struck through, radar = bold title)

    /// After typing: the editor reset the attributes of the edited lines (±1 line) – put the
    /// type styling back for the notes there.
    private func restyleAfterTyping() {
        guard let tv = textView, let range = tv.takeRestyledRange() else { return }
        tv.applyNoteStyles(notes.filter { NSIntersectionRange($0.range, range).length > 0 || NSLocationInRange($0.range.location, range) }.map(style(for:)), restyling: nil)
    }

    private func restyle(_ changed: [Note]) {
        guard let tv = textView, !changed.isEmpty else { return }
        let range = changed.map(\.range).reduce(changed[0].range) { NSUnionRange($0, $1) }
        let around = notes.filter { NSIntersectionRange($0.range, NSRange(location: max(0, range.location - 500), length: range.length + 1000)).length > 0 }
        tv.applyNoteStyles(around.map(style(for:)), restyling: range)
    }

    private func restyleAll() {
        guard let tv = textView else { return }
        tv.applyNoteStyles(notes.map(style(for:)), restyling: NSRange(location: 0, length: (text as NSString).length))
    }

    func editorFontChanged() {
        restyleAll()
        textView?.scheduleIconRefresh()
    }

    private func style(for note: Note) -> NoteTextView.NoteStyle {
        let details = note.detailLines.isEmpty ? nil
            : NSRange(location: note.detailLines[0].range.location, length: NSMaxRange(note.range) - note.detailLines[0].range.location)
        return .init(type: note.type, title: note.firstLine.range, details: details)
    }

    // MARK: - Navigation

    func reveal(_ note: Note) {
        guard let line = resolve(note.firstLine), let tv = textView else { return }
        let current = self.note(containingLine: line.index) ?? note
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: NSMaxRange(line.range), length: 0))
        tv.scrollRangeToVisible(current.range)
        if current.range.length > 0 { tv.showFindIndicator(for: line.range) }
    }

    func setHighlight(_ note: Note?) {
        guard let tv = textView, let lm = tv.layoutManager, let storage = tv.textStorage else { return }
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        guard let note, let line = resolve(note.firstLine), let current = self.note(containingLine: line.index) else { return }
        lm.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.14), forCharacterRange: current.range)
    }

    // MARK: - Editing (through the editor, so ⌘Z works)

    private func resolve(_ line: NoteLine) -> NoteLine? {
        if lines.indices.contains(line.index), lines[line.index].raw == line.raw { return lines[line.index] }
        return lines.filter { $0.raw == line.raw }.min { abs($0.index - line.index) < abs($1.index - line.index) }
    }

    private func linesInSelection(_ selection: NSRange) -> [NoteLine] {
        let start = selection.location
        let end = NSMaxRange(selection)
        return lines.filter { line in
            guard line.range.location <= end, NSMaxRange(line.range) >= start else { return false }
            return selection.length == 0 || line.range.location < end || line.range.location == start
        }
    }

    private func performEdits(_ edits: [Edit], actionName: String) {
        guard loaded, !edits.isEmpty else { return }
        let ascending = edits.sorted { $0.range.location < $1.range.location }
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }

        guard let tv = textView, let storage = tv.textStorage else {
            let m = NSMutableString(string: text)
            for e in ascending.reversed() { m.replaceCharacters(in: e.range, with: e.text) }
            editorDidChange(m as String, editLocation: nil)
            return
        }
        let selection = tv.selectedRange()
        tv.breakUndoCoalescing() // own undo step, separate from what was typed before
        guard tv.shouldChangeText(inRanges: ascending.map { NSValue(range: $0.range) },
                                  replacementStrings: ascending.map(\.text)) else { return }
        storage.beginEditing()
        for e in ascending.reversed() { storage.replaceCharacters(in: e.range, with: e.text) }
        storage.endEditing()
        tv.didChangeText()
        tv.undoManager?.setActionName(actionName)

        let start = Self.map(selection.location, through: ascending)
        let end = Self.map(NSMaxRange(selection), through: ascending)
        tv.setSelectedRange(NSRange(location: min(start, storage.length), length: max(0, min(end, storage.length) - start)))
    }

    /// Moves a cursor position along with the replacements.
    private static func map(_ position: Int, through edits: [Edit]) -> Int {
        var delta = 0
        for e in edits {
            let newLength = (e.text as NSString).length
            if NSMaxRange(e.range) <= position {
                delta += newLength - e.range.length
            } else if e.range.location < position {
                return e.range.location + delta + newLength
            } else {
                break
            }
        }
        return position + delta
    }

    // MARK: - Background

    private func startBackgroundLoop() {
        Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.checkForExternalChanges()
                tick += 1
                if tick % 15 == 0 { self.periodicTick() }
            }
        }
    }

    private func periodicTick() {
        let current = Date()
        if !Calendar.current.isDate(current, inSameDayAs: now) {
            now = current
            updateBadge()
            makeDailyBackup()
        }
        if engine.backend != .appleIntelligence { engine.refreshAvailability() }
        scheduleLinkRefresh() // only refetches previews older than a few minutes
    }

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveNow()
                self?.captureHistory()
            }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForExternalChanges()
                self?.engine.refreshAvailability()
                self?.scheduleLinkRefresh()
            }
        }
    }

    /// When the file was changed from outside (another editor, sync …) we reload –
    /// unless there are unsaved changes here, those win.
    private func checkForExternalChanges() {
        guard loaded, let date = Self.modificationDate(of: fileURL), date != lastModDate else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        lastModDate = date
        guard data != lastSavedData else { return }
        guard let file = try? NotesFile.decoder.decode(NotesFile.self, from: data) else { return }
        guard saveTask == nil else { return } // our own unsaved changes win
        captureHistory()
        lastSavedData = data
        adopt(file)
        setEditorText(text)
        recompute()
        restyleAll()
        captureHistory()
        scheduleAnalysis()
    }

    // MARK: - History

    /// Before text disappears, the state with that text is kept for the history: right away for a
    /// bigger deletion (selection deleted, cut, merge, archive …), and for a run of single
    /// backspaces once it has removed a few characters (fixing a typo doesn't count).
    private func keepStateBeforeDeletion(old: String, new: String) {
        guard loaded else { return }
        let removed = Self.removedLength(from: old, to: new)
        if removed >= 8 {
            keepForHistory((Date(), currentFile()))
            deletionRun = nil
        } else if removed > 0 {
            if deletionRun == nil { deletionRun = (Date(), currentFile(), 0, false) }
            deletionRun!.deleted += removed
            if deletionRun!.deleted >= 8, !deletionRun!.kept, let run = deletionRun {
                keepForHistory((run.date, run.file))
                deletionRun!.kept = true
            }
        } else {
            deletionRun = nil
        }
    }

    private func keepForHistory(_ state: (date: Date, file: NotesFile)) {
        pendingHistory.append(state)
        if pendingHistory.count > 20 { pendingHistory.removeFirst() }
        scheduleHistoryCapture()
    }

    /// Characters replaced or deleted by an edit (common start and end of both texts left out).
    private static func removedLength(from old: String, to new: String) -> Int {
        let a = old as NSString, b = new as NSString
        let shorter = min(a.length, b.length)
        var prefix = 0
        while prefix < shorter, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) { suffix += 1 }
        return a.length - prefix - suffix
    }

    /// A snapshot after 10 s without changes – or right away when the last one is two minutes old.
    private func scheduleHistoryCapture() {
        historyTask?.cancel()
        let overdue = Date().timeIntervalSince(lastHistoryCapture) > 120
        historyTask = Task { [weak self] in
            try? await Task.sleep(for: overdue ? .milliseconds(50) : .seconds(10))
            guard !Task.isCancelled else { return }
            self?.captureHistory()
        }
    }

    /// Writes the kept states and the current one to the history (skipping unchanged ones).
    func captureHistory() {
        guard loaded else { return }
        historyTask?.cancel()
        historyTask = nil
        for state in pendingHistory { history.record(state.file, at: state.date) }
        pendingHistory = []
        history.record(currentFile())
        lastHistoryCapture = Date()
    }

    /// Replaces all notes with an older version (types and dates included). Undoable with ⌘Z;
    /// the current state goes into the history first.
    func restore(_ file: NotesFile) {
        guard loaded, let tv = textView else { return }
        captureHistory()
        let previousRecords = records
        for note in file.notes {
            records[note.id] = NoteRecord(created: note.created, lastChecked: note.lastChecked, type: note.noteType)
        }
        // Let the restored text find the IDs of that version (that's where its types live).
        orphans = matchPool + orphans
        matchPool = file.notes.map { ($0.id, NoteParser.parse($0.title).first?.key ?? "") }
        let undo = tv.undoManager
        undo?.beginUndoGrouping()
        performEdits([(NSRange(location: 0, length: (text as NSString).length), file.render())], actionName: "Restore Version")
        undo?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.replaceRecords(previousRecords) }
        }
        undo?.endUndoGrouping()
        saveNow()
    }

    private func replaceRecords(_ newRecords: [String: NoteRecord]) {
        let current = records
        records = newRecords
        textView?.undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.replaceRecords(current) }
        }
        recompute()
        restyleAll()
        scheduleSave()
    }

    /// Whether a note from the history is in the notes right now (same ID or same title).
    func contains(_ stored: StoredNote) -> Bool {
        let key = NoteParser.parse(stored.title).first?.key ?? ""
        return notes.contains { $0.id == stored.id || (!key.isEmpty && $0.key == key) }
    }

    /// Puts a deleted note back – after the note it followed, else at the end – with its type.
    func putBack(_ stored: StoredNote, after previousID: String?) {
        guard loaded, !contains(stored) else { return }
        let block = stored.lines.joined(separator: "\n")
        let ns = text as NSString
        let edit: Edit
        if let previousID, let before = notes.first(where: { $0.id == previousID }) {
            edit = (NSRange(location: NSMaxRange(before.range), length: 0), "\n\n" + block)
        } else if previousID == nil, let first = notes.first {
            edit = (NSRange(location: first.range.location, length: 0), block + "\n\n")
        } else {
            let separator = ns.length == 0 || text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
            edit = (NSRange(location: ns.length, length: 0), separator + block + "\n")
        }
        records[stored.id] = NoteRecord(created: stored.created, lastChecked: stored.lastChecked, type: stored.noteType)
        orphans.insert((id: stored.id, key: NoteParser.parse(stored.title).first?.key ?? ""), at: 0)
        performEdits([edit], actionName: "Put Back Note")
        if let note = notes.first(where: { $0.id == stored.id }) { reveal(note) }
    }
}

/// One entry of the right-click menu on a note's icon.
struct GutterMenuItem {
    let title: String
    let symbol: String
    var checked = false
    var separatorBefore = false
    let perform: @MainActor () -> Void
}
