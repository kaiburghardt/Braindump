import SwiftUI

/// Right column: Radar (things to keep an eye on), open to-dos and suggestions.
struct SidebarView: View {
    let model: NotesModel
    @AppStorage("showDoneTodos") private var showDone = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    radarSection
                    todoSection
                    suggestionSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            Divider()
            footer
        }
    }

    // MARK: Radar

    private var radarSection: some View {
        let interval = model.checkIntervalDays
        let due = model.radarItems.filter { $0.status(now: model.now, interval: interval) != .fresh }.count
        return VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Radar", count: model.radarItems.count, systemImage: "scope",
                          badge: due > 0 ? "\(due) due" : nil)
            if model.radarItems.isEmpty {
                Hint("Things to keep an eye on. Right-click a note's circle (or ⇧⌘↩) to put it on the radar.")
            }
            ForEach(model.radarItems) { item in
                RadarRow(item: item, model: model)
            }
        }
    }

    // MARK: To-dos

    private var todoSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "To-Dos", count: model.openTodos.count, systemImage: "checkmark.circle")
            if model.openTodos.isEmpty {
                Hint("No open to-dos. Click the circle left of a note (or ⌘↩) to make it one.")
            }
            ForEach(model.openTodos) { note in
                TodoRow(note: note, model: model)
            }
            if !model.doneTodos.isEmpty {
                DisclosureGroup(isExpanded: $showDone) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.doneTodos) { note in
                            TodoRow(note: note, model: model)
                        }
                        Button("Archive Done") { model.archiveDone() }
                            .controlSize(.small)
                            .padding(.top, 6)
                            .padding(.leading, 6)
                            .help("Moves done to-dos into the archive file next to your notes")
                    }
                } label: {
                    Text("Done (\(model.doneTodos.count))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                .padding(.leading, 6)
            }
        }
    }

    // MARK: Suggestions

    private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Suggestions", count: model.suggestions.count, systemImage: "sparkles",
                          busy: model.aiEnabled && model.engine.isWorking)
            if !model.aiEnabled {
                Hint("Suggestions are turned off in Settings.")
            } else if model.suggestions.isEmpty {
                Hint("Just start typing – when a note looks like a to-do or something for your radar, it shows up here.")
            }
            ForEach(model.suggestions) { suggestion in
                SuggestionCard(suggestion: suggestion, model: model)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.snappy, value: model.suggestions)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: model.engine.backend.symbol)
            Text(model.aiEnabled ? model.engine.statusText : "Suggestions off")
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Building blocks

struct SectionHeader: View {
    let title: String
    var count: Int = 0
    var systemImage: String?
    var badge: String?
    var busy = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title.uppercased()).tracking(0.6)
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            if let badge {
                Text(badge)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.16)))
            }
            Spacer()
            if busy { ProgressView().controlSize(.mini) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }
}

/// One thing on the radar: status dot (green → orange → red the longer you haven't looked),
/// title, age, link status and a "checked today" button.
struct RadarRow: View {
    let item: RadarItem
    let model: NotesModel
    @State private var hovering = false

    var body: some View {
        let status = item.status(now: model.now, interval: model.checkIntervalDays)
        let days = item.days(now: model.now)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayTitle(for: item.note))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(Self.ageLabel(days, checked: item.lastChecked != nil))
                        .foregroundStyle(status == .fresh ? Color.secondary : status.color)
                    if let link = item.link {
                        LinkStatusBadge(url: link, preview: model.links.preview(for: link))
                    }
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                Button {
                    withAnimation(.snappy) { model.setType(.note, for: [item.note]) }
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Take off the radar")
            }
            Button {
                withAnimation(.snappy) { model.markChecked(item) }
            } label: {
                Image(systemName: status == .fresh ? "checkmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(status == .fresh ? Color.secondary : status.color)
            }
            .buttonStyle(.plain)
            .help("Checked today – reset the timer")
        }
        .font(.callout)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.reveal(item.note) }
        .help(tooltip)
        .contextMenu {
            Button("Checked Today") { model.markChecked(item) }
            Button("Show in Notes") { model.reveal(item.note) }
            if let link = item.link {
                Button("Open Link") { NSWorkspace.shared.open(link) }
            }
            Divider()
            Button("Make It a To-Do") { model.setType(.todo, for: [item.note]) }
            Button("Take Off the Radar") { model.setType(.note, for: [item.note]) }
            if item.lastChecked != nil {
                Button("Reset Check Date") { model.resetCheck(item) }
            }
        }
    }

    private var tooltip: String {
        let date = item.referenceDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "en_US")))
        return item.lastChecked == nil ? "On the radar since \(date), not checked yet." : "Last checked \(date)."
    }

    static func ageLabel(_ days: Int, checked: Bool) -> String {
        let age = switch days {
        case 0: "today"
        case 1: "yesterday"
        default: "\(days) days ago"
        }
        return checked ? "checked \(age)" : "added \(age)"
    }
}

struct TodoRow: View {
    let note: Note
    let model: NotesModel
    @State private var hovering = false

    var body: some View {
        let done = note.type == .done
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                withAnimation(.snappy) { model.toggleDone(note) }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(done ? "Reopen" : "Done")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayTitle(for: note))
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
                    .lineLimit(3)
                if let detail = note.detailLines.first(where: { !$0.raw.hasPrefix("http") }) {
                    let text = detail.raw.trimmingCharacters(in: .whitespaces)
                    Text(note.detailLines.count > 1 ? "\(text) · +\(note.detailLines.count - 1)" : text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let link = note.link {
                LinkStatusBadge(url: link, preview: model.links.preview(for: link))
            }
        }
        .font(.callout)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.reveal(note) }
        .contextMenu {
            Button(done ? "Reopen" : "Done") { model.toggleDone(note) }
            Button("Show in Notes") { model.reveal(note) }
            Divider()
            Button("Put on Radar") { model.setType(.radar, for: [note]) }
            Button("Make It a Plain Note") { model.setType(.note, for: [note]) }
        }
    }
}

struct SuggestionCard: View {
    let suggestion: Suggestion
    let model: NotesModel
    @State private var hovering = false

    var body: some View {
        let isTodo = suggestion.type == .todo
        VStack(alignment: .leading, spacing: 8) {
            Text(isTodo ? "Looks like a to-do" : "Looks like something for your radar")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.displayTitle(for: suggestion.note))
                .font(.callout)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy) { model.apply(suggestion, as: suggestion.type) }
                } label: {
                    Label(isTodo ? "To-Do" : "Radar", systemImage: isTodo ? "checkmark.circle" : "scope")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(isTodo ? "Radar" : "To-Do") {
                    withAnimation(.snappy) { model.apply(suggestion, as: isTodo ? .radar : .todo) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 0)

                Button {
                    withAnimation(.snappy) { model.dismiss(suggestion) }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss – won't come back for this note")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { inside in
            hovering = inside
            model.setHighlight(inside ? suggestion.note : nil)
        }
        .onTapGesture { model.reveal(suggestion.note) }
    }
}

/// Small status (e.g. "● In Progress") of a Jira/Notion link – otherwise just a link icon.
struct LinkStatusBadge: View {
    let url: URL
    let preview: LinkPreview?

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            if let preview, preview.problem == nil, let status = preview.status, !status.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(preview.state.color).frame(width: 6, height: 6)
                    Text(status).lineLimit(1)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(preview.state.color.opacity(0.14)))
                .fixedSize()
            } else {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(preview.map { [$0.label, $0.title].compactMap { $0 }.joined(separator: " · ") } ?? url.absoluteString)
    }
}

extension LinkPreview.State {
    var color: Color {
        switch self {
        case .done: .green
        case .progress: .blue
        case .todo: .gray
        case .unknown: .orange
        }
    }
}
