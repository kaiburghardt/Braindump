import AppKit

/// Development only: `-notesPath /scratch/Braindump.json -wnSelfTest /path/out`
/// Exercises note blocks, typing mid-line, the note icon (click), typed shortcuts, ↩ for the
/// next to-do, the selection pop-up, merge/split and the mini classifier. Writes a log to
/// /path/out.txt and a picture of the editor (with the pop-up) to /path/out.png.
/// Only runs in test mode (`-notesPath`), so it can never type into the real notes.
@MainActor
enum SelfTest {
    static func runIfRequested(model: NotesModel) {
        guard NotesModel.isTestRun, let out = UserDefaults.standard.string(forKey: "wnSelfTest") else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard let tv = model.textView, let window = tv.window else { return }
            window.makeFirstResponder(tv)
            var log = "== Notes after import\n" + describe(model)
            func flush() { try? log.write(toFile: out + ".partial.txt", atomically: true, encoding: .utf8) }

            flush()
            // Typing in the middle of the first line
            tv.setSelectedRange(NSRange(location: 6, length: 0))
            log += "\n== Typing mid-line\n" + (await type("abc", into: tv, window: window))
            log += "undo manager: \(tv.undoManager.map { "present, canUndo \($0.canUndo)" } ?? "MISSING"), window: \(window.undoManager != nil)\n"

            flush()
            // Icon of a plain note → menu; pick "To-Do". (Menus can't pop up in this test, they'd
            // block – so the items come from the model and are performed directly.)
            @MainActor func typeOf(_ prefix: String) -> String { model.notes.first { $0.title.hasPrefix(prefix) }.map { "\($0.type)" } ?? "?" }
            if let max = model.notes.first(where: { $0.title.hasPrefix("Max") }) {
                let items = model.gutterClick(at: max.firstLine.range.location) ?? []
                log += "\n== Icon menus\nnote menu: " + items.map(\.title).joined(separator: " | ") + "\n"
                items.first { $0.title == "To-Do" }?.perform()
                log += "“Max …” after “To-Do”: \(typeOf("Max"))\n"
            }
            flush()
            // A to-do's icon is a checkbox: a click checks it off right away.
            if let max = model.notes.first(where: { $0.title.hasPrefix("Max") }) {
                click(gutterAt: max.firstLine.range.location, in: tv, window: window)
                try? await Task.sleep(for: .milliseconds(300))
                log += "“Max …” after clicking its checkbox: \(typeOf("Max"))\n"
            }
            flush()
            // Radar icon → menu; take it off the radar, then put it back via the note menu.
            if let us = model.notes.first(where: { $0.title.hasPrefix("US Priority") }) {
                let items = model.gutterClick(at: us.firstLine.range.location) ?? []
                log += "radar menu: " + items.map(\.title).joined(separator: " | ") + "\n"
                items.first { $0.title == "Take Off the Radar" }?.perform()
                log += "“US Priority …” after “Take Off the Radar”: \(typeOf("US Priority")), radar items: \(model.radarItems.count)\n"
                if let again = model.notes.first(where: { $0.title.hasPrefix("US Priority") }) {
                    model.gutterClick(at: again.firstLine.range.location)?.first { $0.title.hasPrefix("Radar") }?.perform()
                    log += "… and back on the radar: \(typeOf("US Priority")), radar items: \(model.radarItems.count)\n"
                }
            }

            flush()
            // Typed shortcut + ↩ for the next to-do, at the end of the document
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            log += "\n== Typed “[ ] Buy milk”, ↩, “Call Max”\n"
            _ = await type("\n[ ] Buy milk", into: tv, window: window)
            try? await Task.sleep(for: .milliseconds(300))
            _ = await type("\r", into: tv, window: window)
            _ = await type("Call Max", into: tv, window: window)
            try? await Task.sleep(for: .milliseconds(400))
            log += describe(model)
            log += "text tail: " + String(tv.string.suffix(40)).debugDescription + "\n"

            // ⇧⌘↩ equivalent: put "Meeting …" on the radar
            flush()
            // (No undo test here: synthetic events never close AppKit's per-event undo group, and
            // closing it by hand broke task scheduling in the test app – crashes and hangs.)
            if let meeting = model.notes.first(where: { $0.title.hasPrefix("Meeting") }) {
                model.setType(.radar, for: [meeting])
                log += "\n“Meeting …” → \(typeOf("Meeting")), radar items: \(model.radarItems.count)\n"
            }

            flush()
            // Select two notes → pop-up → merge → split again
            if let a = model.notes.first(where: { $0.title.hasPrefix("Design") }),
               let b = model.notes.first(where: { $0.title.hasPrefix("Buy") }) {
                tv.setSelectedRange(NSRange(location: a.range.location, length: NSMaxRange(b.range) - a.range.location))
                try? await Task.sleep(for: .milliseconds(400))
                log += "\n== Selection across notes\n" + tv.debugPopup + "\n"
                model.mergeSelection()
                try? await Task.sleep(for: .milliseconds(300))
                log += "after merge:\n" + describe(model)
                if let merged = model.notes.first(where: { $0.title.hasPrefix("Design") }) {
                    tv.setSelectedRange(merged.range)
                    try? await Task.sleep(for: .milliseconds(400))
                    log += "\n== Selection inside one note\n" + tv.debugPopup + "\n"
                    model.splitSelection()
                    try? await Task.sleep(for: .milliseconds(300))
                    log += "after split:\n" + describe(model)
                }
            }

            for _ in 0..<120 where model.engine.backend != .classifier || model.engine.classifierTraining {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(4))
            log += "\n== Mini model: \(model.engine.statusText)\n"
            for s in model.suggestions { log += "suggestion: \(s.type) ← \(s.note.title)\n" }

            model.saveNow()
            log += "\n== File\n" + ((try? String(contentsOf: model.fileURL, encoding: .utf8)) ?? "-") + "\n"

            flush()
            // Picture with the pop-up above two notes
            if let first = model.notes.first(where: { $0.title.hasPrefix("Meeting") }),
               let next = model.notes.first(where: { $0.title.hasPrefix("Max") }) {
                tv.setSelectedRange(NSRange(location: first.range.location, length: NSMaxRange(next.range) - first.range.location))
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? log.write(toFile: out + ".txt", atomically: true, encoding: .utf8)
            if let rep = tv.bitmapImageRepForCachingDisplay(in: tv.visibleRect) {
                tv.cacheDisplay(in: tv.visibleRect, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + ".png"))
            }
        }
    }

    private static func describe(_ model: NotesModel) -> String {
        model.notes.map { note in
            "  [\(note.type)] \(note.title)" + (note.detailLines.isEmpty ? "" : "  (+\(note.detailLines.count) details)")
        }.joined(separator: "\n") + "\n"
    }

    private static func click(gutterAt location: Int, in tv: NSTextView, window: NSWindow) {
        guard let lm = tv.layoutManager else { return }
        let rect = lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: location), effectiveRange: nil)
        let p = tv.convert(NSPoint(x: tv.textContainerOrigin.x - 20, y: rect.midY + tv.textContainerOrigin.y), to: nil)
        if let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            outsideTask { tv.mouseDown(with: ev) }
        }
    }

    /// Runs AppKit event handling as a plain main-queue block – not inside the self-test's Swift
    /// task. Dispatching synthetic events from inside the task crashed in Swift's main-executor checks.
    private static func outsideTask(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    private static func type(_ text: String, into tv: NSTextView, window: NSWindow) async -> String {
        var log = ""
        for ch in text {
            let s = ch == "\n" || ch == "\r" ? "\r" : String(ch)
            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: s,
                                         charactersIgnoringModifiers: s, isARepeat: false, keyCode: s == "\r" ? 36 : 0) {
                outsideTask { tv.keyDown(with: ev) }
            }
            try? await Task.sleep(for: .milliseconds(120))
            log += "  after “\(s == "\r" ? "↩" : s)”: cursor \(tv.selectedRange().location)\n"
        }
        return log
    }
}
