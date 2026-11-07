import Foundation

/// Prompts and answer formats for the AI actions on notes – Tidy Up, Extract To-Dos and Ask.
/// This file only talks to the AI server; `NotesModel` applies the answers to the text (undoable,
/// and only if the note didn't change while the request was running).
@MainActor
enum AIActions {
    // MARK: Tidy Up

    struct Tidied: Decodable {
        let title: String
        let details: [String]
    }

    private static let tidySchema = Schema.object([
        "title": Schema.string,
        "details": Schema.array(Schema.string),
    ])

    private static let tidyInstructions = """
    You clean up one note from the personal scratchpad of a CTO and product manager. Notes are \
    often dictated (speech to text) or typed in a hurry, in German or English.
    Rewrite the note as:
    - title: one short line saying what it is about or what to do, ideally under 80 characters. \
    If it is a task, phrase it as an action ("Ask Max whether the release works on Friday").
    - details: the remaining information as short lines; keep "- " bullets as bullets. Leave it \
    empty if the title already says everything.
    Rules:
    - Never translate. Write in the note's own language: a German note gets a German title and \
    German details, an English note stays English, a mix stays a mix. Example: "also ich muss \
    noch den max anrufen wegen dem vertrag" → title "Max wegen des Vertrags anrufen".
    - Fix speech-to-text mistakes, punctuation and capitalization.
    - Keep every fact, name, number, date and link. Copy URLs character for character.
    - Add nothing that isn't in the note: no greetings, explanations, new facts or new tasks.
    - Plain text only: no Markdown except "- " bullets, no headings, no bold.
    """

    static func tidy(_ note: String, ai: AIService) async throws(AIService.Failure) -> Tidied {
        try await ai.complete(Tidied.self, task: "tidy_note", system: tidyInstructions,
                              user: "The note:\n\n" + note, schema: tidySchema, maxTokens: 3000)
    }

    // MARK: Extract To-Dos

    struct Extracted: Decodable {
        struct Item: Decodable {
            let title: String
            let details: [String]
            let type: String
        }
        let items: [Item]
    }

    private static let extractSchema = Schema.object([
        "items": Schema.array(Schema.object([
            "title": Schema.string,
            "details": Schema.array(Schema.string),
            "type": Schema.oneOf(["todo", "radar", "note"]),
        ])),
    ])

    private static let extractInstructions = """
    You turn a piece of text from the personal scratchpad of a CTO and product manager – meeting \
    notes, a pasted chat thread, a long brain dump – into separate items for their notes.
    For each item:
    - title: one short line (under 80 characters); phrased as an action for tasks ("Send Lisa the \
    pricing deck", "Lisa das Pricing-Deck schicken").
    - details: only facts from the text that this item needs (names, numbers, dates, links), as \
    short lines. Often empty.
    - type: "todo" = something the author has to do personally; "radar" = something other people \
    do that the author wants to follow up on or check later ("Tom fixes the login bug"); \
    "note" = a decision, fact or idea worth keeping on its own.
    Rules:
    - Never translate: write every item in the language of the text it comes from (German stays German).
    - Only what is in the text: never invent tasks, owners or dates.
    - Skip small talk and things that are already done.
    - At most 15 items, most important first.
    - Copy URLs character for character. Plain text only, no Markdown except "- " bullets in details.
    """

    static func extract(_ text: String, today: Date, ai: AIService) async throws(AIService.Failure) -> Extracted {
        let user = "Today is \(isoDay(today)).\n\nThe text:\n\n" + text
        return try await ai.complete(Extracted.self, task: "extract_items", system: extractInstructions,
                                     user: user, schema: extractSchema, maxTokens: 6000)
    }

    // MARK: Ask

    struct Answer: Decodable {
        let answer: String
        let notes: [Int]
    }

    private static let askSchema = Schema.object([
        "answer": Schema.string,
        "notes": Schema.array(Schema.integer),
    ])

    private static let askInstructions = """
    You answer questions about the personal notes of a CTO and product manager. Their notes are \
    listed below, each with a number in brackets, its type and dates. Types: todo = open to-do, \
    done = finished to-do, radar = something they keep an eye on – usually work other people are \
    doing that they are waiting for or want to follow up on, note = anything else.
    - Answer only from these notes. If they don't contain the answer, say so in one sentence.
    - Be brief: a sentence or a few short "- " lines. Plain text, no Markdown headings or bold.
    - Answer in the language of the question and address the author as "you" (in German "du").
    - In "notes", list the numbers of the notes your answer is based on (at most 8), most relevant first.
    """

    static func ask(_ question: String, notes context: String, earlier: [(question: String, answer: String)],
                    ai: AIService) async throws(AIService.Failure) -> Answer {
        var user = context
        if !earlier.isEmpty {
            user += "\n\nEarlier in this conversation:\n"
            for turn in earlier.suffix(4) { user += "Q: \(turn.question)\nA: \(turn.answer)\n" }
        }
        user += "\n\nQuestion: " + question
        return try await ai.complete(Answer.self, task: "answer_question", system: askInstructions,
                                     user: user, schema: askSchema, maxTokens: 3000)
    }

    /// All notes as numbered lines for the Ask prompt ("[3] (radar, created 2026-11-02, checked …) Title").
    static func context(for notes: [Note], today: Date) -> String {
        var lines = ["Today is \(isoDay(today)).", "", "Notes:"]
        for (i, note) in notes.enumerated() where !note.title.isEmpty {
            var meta = [note.type == .radar ? "radar" : note.type.rawValue, "created \(isoDay(note.created))"]
            if let checked = note.lastChecked { meta.append("checked \(isoDay(checked))") }
            lines.append("[\(i + 1)] (\(meta.joined(separator: ", "))) \(note.title)")
            for detail in note.detailLines where !detail.body.isEmpty { lines.append("    \(detail.body)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// Lines that can go into the editor as they are: no line breaks inside, no blank lines (they
    /// would end the note), no typed shortcuts or heading marks (they would split it).
    static func cleanTitle(_ text: String) -> String {
        clean(text.replacingOccurrences(of: "\n", with: " "))
    }

    static func cleanDetails(_ details: [String]) -> [String] {
        details.flatMap { $0.components(separatedBy: .newlines) }
            .map { line in
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                return String(indent) + clean(String(line.dropFirst(indent.count)))
            }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func clean(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for marker in ["[ ]", "[x]", "[X]", "\u{1F6A7}", "#"] where s.hasPrefix(marker) {
                s = String(s.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return s
    }

    /// Title line plus detail lines, as editor text.
    static func render(title: String, details: [String]) -> String {
        ([cleanTitle(title)] + cleanDetails(details)).joined(separator: "\n")
    }

    /// Links of the original that the new text no longer contains.
    static func missingURLs(original: String, result: String) -> [URL] {
        let kept = Set(NoteParser.urlRanges(in: result).map(\.url.absoluteString))
        return NoteParser.urlRanges(in: original).map(\.url).filter { !kept.contains($0.absoluteString) }
    }

    static func isoDay(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }
}
