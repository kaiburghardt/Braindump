import AppKit

/// Development only: `-notesPath /scratch/Braindump.json -wnRenderTest /path/out`, driven by
/// `Tools/ui_test.sh`. Adds and removes lines in different places and pauses after every step,
/// so the script can capture the real window (`screencapture -l`). Drawing bugs – stale lines
/// left on screen – only show up there, not in a fresh `cacheDisplay` rendering.
///
/// Handshake per step N: the app writes `out.N.ready` ("<windowID> <step name>"), the script
/// captures the window and writes `out.N.done`. When everything ran, `out.log` is written.
@MainActor
enum RenderTest {
    static func runIfRequested(model: NotesModel) {
        guard NotesModel.isTestRun, let out = UserDefaults.standard.string(forKey: "wnRenderTest") else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard let tv = model.textView, let window = tv.window else { return }
            window.makeFirstResponder(tv)
            var step = 0
            var log = ""

            /// Waits for the script to capture the window (`out.N<suffix>.png`).
            @MainActor func capture(_ name: String, _ suffix: String, of captured: NSWindow? = nil) async {
                let base = "\(out).\(step)\(suffix)"
                try? "\((captured ?? window).windowNumber) \(name)".write(toFile: base + ".ready", atomically: true, encoding: .utf8)
                for _ in 0..<150 where !FileManager.default.fileExists(atPath: base + ".done") {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            /// Captures the window as it is ("a"), checks the layout against a fresh one, then forces
            /// a full redraw and captures again ("b"). The script compares a and b: any difference
            /// means something on screen wasn't redrawn.
            @MainActor func checkpoint(_ name: String) async {
                step += 1
                try? await Task.sleep(for: .milliseconds(600))
                log += "\(step) \(name): \(model.notes.count) notes, \((tv.string as NSString).length) chars\n"
                await capture(name, "a")
                for problem in layoutProblems(tv) { log += "   LAYOUT: \(problem)\n" }
                forceRedraw(window)
                try? await Task.sleep(for: .milliseconds(300))
                await capture(name, "b")
            }
            @MainActor func press(_ count: Int, keyCode: UInt16, _ characters: String, every delay: Int = 120) async {
                for _ in 0..<count {
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: characters,
                                                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
                        SelfTest.outsideTask { tv.keyDown(with: event) }
                    }
                    try? await Task.sleep(for: .milliseconds(delay))
                }
            }
            @MainActor func returns(_ count: Int, every delay: Int = 120) async { await press(count, keyCode: 36, "\r", every: delay) }
            @MainActor func backspaces(_ count: Int, every delay: Int = 120) async { await press(count, keyCode: 51, "\u{7F}", every: delay) }
            @MainActor func cursor(_ location: Int) {
                tv.setSelectedRange(NSRange(location: min(location, (tv.string as NSString).length), length: 0))
            }
            @MainActor func endOfTitle(_ prefix: String) -> Int? {
                model.notes.first { $0.title.hasPrefix(prefix) }.map { NSMaxRange($0.firstLine.range) }
            }

            await checkpoint("initial")

            if let end = endOfTitle("Send off") {
                cursor(end)
                await returns(3)
                await checkpoint("3 × return after a title in the middle")
                await backspaces(3)
                await checkpoint("3 × backspace again")
            }

            cursor((tv.string as NSString).length)
            await returns(4)
            await checkpoint("4 × return at the end")
            await backspaces(4)
            await checkpoint("4 × backspace at the end")

            if let end = endOfTitle("Book a dentist") {
                cursor(end)
                await returns(2)
                _ = await SelfTest.type("New note", into: tv, window: window)
                await checkpoint("new note typed in the middle")
                await backspaces(10)
                await checkpoint("new note deleted with backspace")
            }

            if let garden = model.notes.first(where: { $0.title.contains("Garden") }) {
                tv.setSelectedRange(NSRange(location: garden.range.location, length: NSMaxRange(garden.range) - garden.range.location + 1))
                await backspaces(1)
                await checkpoint("multi-line note deleted")
                _ = await SelfTest.type("Short", into: tv, window: window)
                await checkpoint("typed after the deletion")
            }

            // Blank lines added below a note, the cursor moved away, the lines removed again
            if let end = endOfTitle("Landlord") {
                cursor(end)
                await returns(2)
                await checkpoint("2 × return: cursor on a new blank line")
                cursor(0)
                await checkpoint("cursor left the blank lines")
                cursor(end + 2)
                await backspaces(2)
                await checkpoint("blank lines removed again")
            }

            // Copying gives plain text (on a private pasteboard – never the real clipboard)
            if let weekend = model.notes.first(where: { $0.title.hasPrefix("Weekend") }) {
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("BraindumpRenderTest-\(UUID().uuidString)"))
                tv.setSelectedRange(NSRange(location: weekend.range.location, length: 30))
                _ = tv.writeSelection(to: pasteboard, types: tv.writablePasteboardTypes)
                log += "copy: types \((pasteboard.types ?? []).map(\.rawValue)), text \((pasteboard.string(forType: .string) ?? "-").debugDescription)\n"
                pasteboard.releaseGlobally()
                cursor(0)
            }

            // Key repeat: several edits per frame, around a multi-line note (splits it and joins it again)
            if let end = endOfTitle("Weekend") {
                cursor(end)
                await returns(6, every: 30)
                await checkpoint("key repeat: 6 × return after a multi-line title")
                await backspaces(6, every: 30)
                await checkpoint("key repeat: 6 × backspace again")
            }

            // Return in the middle of a line, then join it again
            if let end = endOfTitle("Pick up") {
                cursor(end - 10)
                await returns(1)
                await checkpoint("line split in the middle")
                await backspaces(1)
                await checkpoint("line joined again")
            }

            // Long document, scrolled to the end
            let filler = (1...40).map { "Filler note \($0)\nwith a detail line" }.joined(separator: "\n\n")
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.insertText("\n" + filler + "\n", replacementRange: tv.selectedRange())
            tv.scrollRangeToVisible(tv.selectedRange())
            await checkpoint("long document, scrolled to the end")
            await returns(8, every: 30)
            await checkpoint("long: key repeat 8 × return at the end")
            await backspaces(8, every: 30)
            await checkpoint("long: key repeat 8 × backspace at the end")
            if let end = endOfTitle("Filler note 35") {
                cursor(end)
                tv.scrollRangeToVisible(tv.selectedRange())
                await returns(5, every: 30)
                await checkpoint("long: 5 × return in the visible middle")
                await backspaces(5, every: 30)
                await checkpoint("long: 5 × backspace in the visible middle")
                let ns = tv.string as NSString
                let start = ns.lineRange(for: NSRange(location: end, length: 0)).location
                let block = NSRange(location: start, length: min(ns.length, end + 200) - start)
                tv.setSelectedRange(ns.lineRange(for: block))
                await backspaces(1)
                await checkpoint("long: several notes deleted at once")
            }

            // History: versions kept before deletions, a deleted note put back, the window itself
            model.captureHistory()
            log += "history: \(model.history.entries.count) versions\n"
            for entry in model.history.entries.prefix(6) {
                let changes = NoteChange.between(model.history.previous(of: entry).flatMap(model.history.file(for:)),
                                                 model.history.file(for: entry)!)
                log += "  " + changes.map { "\($0.kind) “\($0.note.title.prefix(24))”" }.joined(separator: ", ") + "\n"
            }
            let deleted = model.history.entries.lazy.compactMap { entry -> NoteChange? in
                guard let file = model.history.file(for: entry) else { return nil }
                return NoteChange.between(model.history.previous(of: entry).flatMap(model.history.file(for:)), file)
                    .first { $0.kind == .removed && !model.contains($0.note) }
            }.first
            if let deleted {
                model.putBack(deleted.note, after: deleted.previousID)
                let back = model.notes.first { $0.id == deleted.id }
                log += "put back “\(deleted.note.title)”: \(back.map { "present as \($0.type), id kept" } ?? "MISSING")\n"
            }
            if let oldest = model.history.entries.last, let file = model.history.file(for: oldest) {
                model.restore(file)
                log += "restored oldest version: \(model.notes.count) notes (version has \(file.notes.count)), types "
                    + (model.notes.map(\.type.rawValue) == file.notes.map(\.type) ? "match" : "DIFFER") + "\n"
            }
            if let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Note" })?.submenu,
               let index = menu.items.firstIndex(where: { $0.title == "Show History" }) {
                menu.performActionForItem(at: index)
                try? await Task.sleep(for: .seconds(1.5))
                if let historyWindow = NSApp.windows.first(where: { $0.title == "History" && $0.isVisible }) {
                    historyWindow.orderBack(nil) // never in front of the user's windows
                    try? await Task.sleep(for: .milliseconds(500))
                    step += 1
                    await capture("history window", "a", of: historyWindow)
                    await capture("history window", "b", of: historyWindow)
                }
            }

            try? log.write(toFile: out + ".log", atomically: true, encoding: .utf8)
        }
    }

    /// Redraws every view in the window from scratch.
    static func forceRedraw(_ window: NSWindow) {
        func mark(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(mark)
        }
        if let frame = window.contentView?.superview { mark(frame) }
        window.displayIfNeeded()
    }

    /// Lays the same text out once more from scratch and compares the line positions with the
    /// editor's layout – a difference means the editor kept a stale layout.
    static func layoutProblems(_ tv: NSTextView) -> [String] {
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let storage = tv.textStorage else { return ["no layout"] }
        let copy = NSTextStorage(attributedString: storage)
        let freshLM = NSLayoutManager()
        copy.addLayoutManager(freshLM)
        let freshTC = NSTextContainer(size: tc.size)
        freshTC.lineFragmentPadding = tc.lineFragmentPadding
        freshLM.addTextContainer(freshTC)
        freshLM.delegate = lm.delegate
        lm.ensureLayout(for: tc)
        freshLM.ensureLayout(for: freshTC)
        var problems: [String] = []
        let ns = storage.string as NSString
        var location = 0
        while location < ns.length, problems.count < 5 {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let live = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: location), effectiveRange: nil)
            let fresh = freshLM.lineFragmentRect(forGlyphAt: freshLM.glyphIndexForCharacter(at: location), effectiveRange: nil)
            if abs(live.minY - fresh.minY) > 0.5 || abs(live.height - fresh.height) > 0.5 {
                let text = ns.substring(with: paragraph).trimmingCharacters(in: .newlines)
                problems.append("line at \(location) “\(text.prefix(30))”: y \(live.minY)/\(live.height) on screen, \(fresh.minY)/\(fresh.height) fresh")
            }
            location = NSMaxRange(paragraph)
        }
        return problems
    }
}
