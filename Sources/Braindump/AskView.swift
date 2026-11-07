import SwiftUI

/// ⌘K: ask a question about all notes in the file. The answer names the notes it is based on;
/// clicking one shows it in the editor. The conversation lasts while the sheet is open – nothing
/// is stored.
struct AskView: View {
    let model: NotesModel
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var turns: [Turn] = []
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
        let notes: [Note]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Ask Braindump", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if !turns.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(turns) { turn in
                                TurnView(turn: turn, model: model) { dismiss() }
                                    .id(turn.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: turns.count) { _, _ in
                        if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                    }
                }
            }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                TextField(turns.isEmpty ? "What am I waiting on? What did I note about …?" : "Ask a follow-up …", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Ask", action: send)
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Text("Sends all notes of this file to \(model.ai.host).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 540)
        .onAppear { focused = true }
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true
        error = nil
        let notes = model.notes
        let context = AIActions.context(for: notes, today: Date())
        let earlier = turns.map { (question: $0.question, answer: $0.answer) }
        Task {
            defer {
                busy = false
                focused = true
            }
            do throws(AIService.Failure) {
                let answer = try await AIActions.ask(text, notes: context, earlier: earlier, ai: model.ai)
                var seen = Set<Int>()
                let referenced = answer.notes
                    .filter { notes.indices.contains($0 - 1) && seen.insert($0).inserted }
                    .prefix(8)
                    .map { notes[$0 - 1] }
                turns.append(Turn(question: text, answer: answer.answer, notes: Array(referenced)))
                question = ""
            } catch {
                self.error = error.message
            }
        }
    }
}

private struct TurnView: View {
    let turn: AskView.Turn
    let model: NotesModel
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.question)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(turn.answer)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !turn.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(turn.notes) { note in
                        Button {
                            // The note may have moved since the question – find it by ID.
                            model.reveal(model.notes.first { $0.id == note.id } ?? note)
                            onReveal()
                        } label: {
                            Label(model.displayTitle(for: note), systemImage: Self.symbol(for: note.type))
                                .lineLimit(1)
                                .font(.callout)
                        }
                        .buttonStyle(.link)
                        .help("Show this note")
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private static func symbol(for type: NoteType) -> String {
        switch type {
        case .note: "circle.dashed"
        case .todo: "circle"
        case .done: "checkmark.circle.fill"
        case .radar: "scope"
        }
    }
}
