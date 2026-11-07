import SwiftUI

/// The History window: versions of the last hours on the left, what changed in the selected
/// version on the right (compared with the version before). Deleted notes can be put back,
/// a whole version restored.
struct HistoryView: View {
    let model: NotesModel
    @State private var selection: HistoryStore.Entry?

    private var history: HistoryStore { model.history }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.entries) { entry in
                            HistoryRow(entry: entry, changes: changes(for: entry))
                                .tag(entry)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
            .overlay {
                if history.entries.isEmpty {
                    ContentUnavailableView("No History Yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Versions show up here a few seconds after you change something."))
                }
            }
        } detail: {
            if let entry = selection, let file = history.file(for: entry) {
                HistoryDetail(model: model, entry: entry, file: file,
                              previous: history.previous(of: entry), changes: changes(for: entry))
                    .id(entry)
            } else {
                ContentUnavailableView("Pick a Version", systemImage: "clock",
                                       description: Text("You'll see what changed compared with the version before."))
            }
        }
        .navigationTitle("History")
        .onAppear {
            model.captureHistory()
            if selection == nil { selection = history.entries.first }
        }
        .onChange(of: history.entries.first) { _, newest in
            // Follow along while the newest version is selected.
            if selection == nil || selection == history.entries.dropFirst().first { selection = newest }
        }
    }

    private func changes(for entry: HistoryStore.Entry) -> [NoteChange] {
        guard let file = history.file(for: entry) else { return [] }
        return NoteChange.between(history.previous(of: entry).flatMap(history.file(for:)), file)
    }

    private var groups: [(title: String, entries: [HistoryStore.Entry])] {
        let now = Date()
        let calendar = Calendar.current
        var result: [(title: String, entries: [HistoryStore.Entry])] = []
        for entry in history.entries {
            let title: String
            if now.timeIntervalSince(entry.date) < 3600 {
                title = "Last Hour"
            } else if calendar.isDateInToday(entry.date) {
                title = "Earlier Today"
            } else if calendar.isDateInYesterday(entry.date) {
                title = "Yesterday"
            } else {
                title = entry.date.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: Locale(identifier: "en_US")))
            }
            if result.last?.title == title { result[result.count - 1].entries.append(entry) } else { result.append((title, [entry])) }
        }
        return result
    }
}

private struct HistoryRow: View {
    let entry: HistoryStore.Entry
    let changes: [NoteChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_US"))))
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                Spacer()
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let added = changes.filter { $0.kind == .added }.count
        let removed = changes.filter { $0.kind == .removed }.count
        let edited = changes.filter { $0.kind == .edited && $0.textChanged }.count
        let retyped = changes.filter(\.typeChanged).count
        var parts: [String] = []
        if removed > 0 { parts.append("\(removed) deleted") }
        if added > 0 { parts.append("\(added) added") }
        if edited > 0 { parts.append("\(edited) edited") }
        if retyped > 0 { parts.append("\(retyped) \(retyped == 1 ? "type" : "types") changed") }
        if parts.isEmpty { return changes.isEmpty ? "Dates or order changed" : "–" }
        // Lead with what's most likely looked for.
        return parts.joined(separator: " · ")
    }
}

private struct HistoryDetail: View {
    let model: NotesModel
    let entry: HistoryStore.Entry
    let file: NotesFile
    let previous: HistoryStore.Entry?
    let changes: [NoteChange]
    @State private var confirmRestore = false

    private static let time = Date.FormatStyle(date: .omitted, time: .standard, locale: Locale(identifier: "en_US"))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.date.formatted(Date.FormatStyle(date: .complete, time: .shortened, locale: Locale(identifier: "en_US"))))
                        .font(.title3.weight(.semibold))
                    Text(previous.map { "Changes since \($0.date.formatted(Self.time)) · \(file.notes.count) notes in this version" }
                         ?? "Oldest version in the history · \(file.notes.count) notes")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if changes.isEmpty {
                    Text("No text or type changes – only check dates or the order of notes.")
                        .foregroundStyle(.secondary)
                }
                ForEach(changes) { change in
                    ChangeCard(model: model, change: change, showsPutBack: previous != nil)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    confirmRestore = true
                } label: {
                    Label("Restore This Version", systemImage: "arrow.uturn.backward")
                }
                .help("Replace your notes with this version – undo with ⌘Z in the editor")
            }
        }
        .confirmationDialog("Restore the version from \(entry.date.formatted(Self.time))?", isPresented: $confirmRestore) {
            Button("Restore") { model.restore(file) }
        } message: {
            Text("Your notes are replaced with this version. Undo with ⌘Z in the editor – the current state also stays in the history.")
        }
    }
}

private struct ChangeCard: View {
    let model: NotesModel
    let change: NoteChange
    let showsPutBack: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.callout.weight(.semibold))
                if change.typeChanged, let old = change.old, let new = change.new {
                    TypeBadge(type: old.noteType)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    TypeBadge(type: new.noteType)
                } else if change.note.noteType != .note {
                    TypeBadge(type: change.note.noteType)
                }
                Spacer()
                if change.kind == .removed, showsPutBack {
                    if model.contains(change.note) {
                        Text("In your notes").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Put Back") { model.putBack(change.note, after: change.previousID) }
                            .controlSize(.small)
                            .help("Insert this note where it was")
                    }
                }
            }
            if change.textChanged || change.kind != .edited {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line, font: Font(model.editorFont.font(scale: 0.93)))
                    }
                }
                .textSelection(.enabled)
            } else {
                Text(change.note.title)
                    .font(Font(model.editorFont.font(scale: 0.93)))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var lines: [DiffLine] {
        switch change.kind {
        case .added: change.note.lines.map { DiffLine(kind: .added, text: $0) }
        case .removed: change.note.lines.map { DiffLine(kind: .removed, text: $0) }
        case .edited: change.lineDiff
        }
    }

    private var title: String {
        switch change.kind {
        case .added: "Added"
        case .removed: "Deleted"
        case .edited: change.textChanged ? "Edited" : "Type changed"
        }
    }

    private var symbol: String {
        switch change.kind {
        case .added: "plus.circle.fill"
        case .removed: "minus.circle.fill"
        case .edited: change.textChanged ? "pencil.circle.fill" : "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private var tint: Color {
        switch change.kind {
        case .added: .green
        case .removed: .red
        case .edited: .blue
        }
    }
}

private struct DiffLineView: View {
    let line: DiffLine
    let font: Font

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .foregroundStyle(color)
                .frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .same ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(font)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(line.kind == .same ? Color.clear : color.opacity(0.12)))
    }

    private var marker: String {
        switch line.kind {
        case .same: " "
        case .added: "+"
        case .removed: "−"
        }
    }

    private var color: Color {
        switch line.kind {
        case .same: .secondary
        case .added: .green
        case .removed: .red
        }
    }
}

private struct TypeBadge: View {
    let type: NoteType

    var body: some View {
        Label(type.displayName, systemImage: type.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

extension NoteType {
    var displayName: String {
        switch self {
        case .note: "Note"
        case .todo: "To-Do"
        case .done: "Done"
        case .radar: "Radar"
        }
    }

    var symbol: String {
        switch self {
        case .note: "circle.dashed"
        case .todo: "circle"
        case .done: "checkmark.circle.fill"
        case .radar: "scope"
        }
    }
}
