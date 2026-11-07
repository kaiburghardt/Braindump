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

            flush()
            log += await aiSection(model: model, tv: tv, flush: { partial in
                try? (log + partial).write(toFile: out + ".partial.txt", atomically: true, encoding: .utf8)
            })

            model.saveNow()
            log += "\n== File\n" + ((try? String(contentsOf: model.fileURL, encoding: .utf8)) ?? "-") + "\n"

            flush()
            // Picture with the pop-up above two notes
            if let first = model.notes.first(where: { $0.title.hasPrefix("Meeting") }),
               let next = model.notes.first(where: { $0.title.hasPrefix("Max") }) {
                let start = min(first.range.location, next.range.location)
                let end = max(NSMaxRange(first.range), NSMaxRange(next.range))
                tv.setSelectedRange(NSRange(location: start, length: end - start))
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? log.write(toFile: out + ".txt", atomically: true, encoding: .utf8)
            if let rep = tv.bitmapImageRepForCachingDisplay(in: tv.visibleRect) {
                tv.cacheDisplay(in: tv.visibleRect, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + ".png"))
            }
        }
    }

    // MARK: AI probe against a real server

    /// Development only: `-notesPath … -aiBaseURL … -aiModel … -aiKeyFile … -wnAIProbe /path/out.txt`
    /// Sends one real request per AI feature to the server given on the command line and logs
    /// answers and timings – to check that a server and model work with Braindump. The key comes
    /// from a file, so it never shows up in the process list.
    static func runAIProbeIfRequested(model: NotesModel) {
        guard NotesModel.isTestRun, let out = UserDefaults.standard.string(forKey: "wnAIProbe") else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            var log = "server: \(model.ai.host), model: \(model.ai.model), configured: \(model.ai.isConfigured)\n"
            func write() { try? log.write(toFile: out, atomically: true, encoding: .utf8) }
            func ms(since start: Date) -> String { "\(Int(Date().timeIntervalSince(start) * 1000)) ms" }

            // Suggestions run by themselves in the background – wait for them.
            var start = Date()
            for _ in 0..<300 where model.engine.backend != .server || model.engine.isWorking || model.suggestions.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            }
            log += "\n== Suggestions (\(ms(since: start)), backend \(model.engine.backend))\n"
            for s in model.suggestions { log += "  \(s.type) ← \(s.note.title)\n" }
            write()

            start = Date()
            do throws(AIService.Failure) {
                let dictated = "also ich muss noch mal den max anrufen wegen dem vertrag der muss bis freitag raus " +
                    "und danach noch mit lisa die preise für holland durchgehen https://example.com/contract"
                let tidied = try await AIActions.tidy(dictated, ai: model.ai)
                log += "\n== Tidy Up (\(ms(since: start)))\n" + AIActions.render(title: tidied.title, details: tidied.details) + "\n"
                log += "links kept: \(AIActions.missingURLs(original: dictated, result: AIActions.render(title: tidied.title, details: tidied.details)).isEmpty)\n"
            } catch {
                log += "\n== Tidy Up FAILED (\(ms(since: start))): \(error.message)\n"
            }
            write()

            start = Date()
            do throws(AIService.Failure) {
                let meeting = """
                Weekly with Tom and Lisa
                - Tom: login bug on Android still open, he fixes it before the release on Thursday
                - Lisa needs the updated pricing deck from me by Wednesday
                - we decided to keep the free tier as it is
                - I should ask finance about the Q4 budget
                - nice weather today :)
                """
                let result = try await AIActions.extract(meeting, today: Date(), ai: model.ai)
                log += "\n== Extract To-Dos (\(ms(since: start)))\n"
                for item in result.items { log += "  [\(item.type)] \(item.title)" + (item.details.isEmpty ? "" : " / " + item.details.joined(separator: " / ")) + "\n" }
            } catch {
                log += "\n== Extract FAILED (\(ms(since: start))): \(error.message)\n"
            }
            write()

            start = Date()
            do throws(AIService.Failure) {
                let notes = model.notes
                let answer = try await AIActions.ask("Worauf warte ich gerade?", notes: AIActions.context(for: notes, today: Date()),
                                                     earlier: [], ai: model.ai)
                log += "\n== Ask (\(ms(since: start)))\n\(answer.answer)\nnotes: " +
                    answer.notes.compactMap { notes.indices.contains($0 - 1) ? notes[$0 - 1].title : nil }.joined(separator: " | ") + "\n"
            } catch {
                log += "\n== Ask FAILED (\(ms(since: start))): \(error.message)\n"
            }
            log += "\nparameters left out for this model: " + (model.ai.droppedParameters.isEmpty ? "none" : model.ai.droppedParameters.joined(separator: ", ")) + "\n"
            log += "DONE\n"
            write()
        }
    }

    // MARK: AI (answered by AIStub – never a real server)

    /// Suggestions from the AI server (rules still win), Tidy Up (type and links kept, rejected
    /// when a link goes missing, discarded when the note changed meanwhile), Extract To-Dos, Ask,
    /// and that nothing AI-related shows up or calls out once the server is removed.
    private static func aiSection(model: NotesModel, tv: NoteTextView, flush: (String) -> Void) async -> String {
        var log = "\n== AI (stub server)\n"
        AIStub.install { task, body in
            let messages = body["messages"] as? [[String: Any]] ?? []
            let user = messages.last?["content"] as? String ?? ""
            switch task {
            case "classify_notes":
                // Numbered titles: "anrufen" → todo, "rollout" → radar, "TODO" → radar (the rule must win).
                var lines: [[String: Any]] = []
                for line in user.split(separator: "\n") {
                    guard let match = line.wholeMatch(of: /(\d+)\. (.*)/) else { continue }
                    let title = match.2.lowercased()
                    let category = title.contains("anrufen") ? "todo" : (title.contains("rollout") || title.contains("todo")) ? "radar" : "note"
                    lines.append(["line": Int(match.1)!, "category": category])
                }
                return ["lines": lines]
            case "tidy_note":
                if user.contains("SLOW") { Thread.sleep(forTimeInterval: 1.5) }
                if user.contains("DROP-LINK") { return ["title": "Tidied, but the link is gone", "details": [String]()] }
                return ["title": "Ask Max about the contract", "details": ["- by Friday", "https://example.com/contract"]]
            case "extract_items":
                return ["items": [
                    ["title": "Send Lisa the deck", "details": [String](), "type": "todo"],
                    ["title": "Tom fixes the login bug", "details": ["- before the release"], "type": "radar"],
                    ["title": "[ ] Pricing stays as it is", "details": ["", "# no heading"], "type": "note"],
                ]]
            case "answer_question":
                return ["answer": "You are waiting on Tom (login bug).", "notes": [1, 2, 99]]
            default:
                return nil
            }
        }
        @MainActor func note(_ prefix: String) -> Note? { model.notes.first { $0.title.hasPrefix(prefix) } }
        @MainActor func append(_ text: String) async {
            outsideTask {
                let end = (tv.string as NSString).length
                tv.insertText(text, replacementRange: NSRange(location: end, length: 0))
                tv.setSelectedRange(NSRange(location: 0, length: 0))
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        @MainActor func waitWhileBusy(_ seconds: Double = 4) async {
            try? await Task.sleep(for: .milliseconds(150))
            for _ in 0..<Int(seconds * 10) where (0..<((tv.string as NSString).length + 1)).contains(where: model.isAIBusy(at:)) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(300))
        }

        log += "configured before: \(model.ai.isConfigured), gutter items: " + (model.notes.first.map { model.gutterMenuItems(at: $0.firstLine.range.location).map(\.title).joined(separator: " | ") } ?? "-") + "\n"
        await append("\n\nTODO check that the rule wins over the stub\n\nRollout of the new app version")
        model.ai.configureForTesting(baseURL: "https://ai.stub.invalid", model: "stub-model")
        for _ in 0..<60 where !AIStub.answeredTasks.contains("classify_notes") || model.engine.isWorking {
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .milliseconds(500))
        log += "backend: \(model.engine.backend), status: \(model.engine.statusText)\n"
        for s in model.suggestions { log += "suggestion: \(s.type) ← \(s.note.title)\n" }
        if let first = model.notes.first {
            log += "gutter items: " + model.gutterMenuItems(at: first.firstLine.range.location).map(\.title).joined(separator: " | ") + "\n"
        }
        flush(log)

        // Tidy Up: a dictated to-do with a link
        await append("\n\nmax anrufen wegen dem vertrag bis freitag https://example.com/contract")
        if let dictated = note("max anrufen") {
            model.setType(.todo, for: [dictated])
            model.tidyUp(note("max anrufen") ?? dictated)
            log += "\n-- Tidy Up: icon busy while waiting: \(model.isAIBusy(at: dictated.firstLine.range.location))\n"
            await waitWhileBusy()
            if let tidied = note("Ask Max about the contract") {
                log += "tidied: [\(tidied.type)] \(tidied.title) / " + tidied.detailLines.map(\.body).joined(separator: " / ") + "\n"
            } else {
                log += "tidied note MISSING; notice: \(model.aiNotice ?? "-")\n"
            }
        }
        flush(log)

        // Tidy Up that loses a link → nothing changes
        await append("\n\nDROP-LINK check https://example.com/keep")
        if let dropping = note("DROP-LINK") {
            model.tidyUp(dropping)
            await waitWhileBusy()
            log += "\n-- Link guard: note still there: \(note("DROP-LINK") != nil), notice: \(model.aiNotice ?? "-")\n"
        }
        flush(log)

        // The note changes while the AI is working → the answer is discarded
        await append("\n\nSLOW note to tidy")
        if let slow = note("SLOW") {
            model.tidyUp(slow)
            try? await Task.sleep(for: .milliseconds(300))
            outsideTask {
                tv.insertText(" (edited)", replacementRange: NSRange(location: NSMaxRange(slow.firstLine.range), length: 0))
            }
            await waitWhileBusy()
            log += "\n-- Stale answer: note now “\(note("SLOW")?.title ?? "MISSING")”, tidied copies: \(model.notes.filter { $0.title == "Ask Max about the contract" }.count), notice: \(model.aiNotice ?? "-")\n"
        }
        flush(log)

        // Extract To-Dos from a meeting blob
        await append("\n\nCall notes with Tom and Lisa\nLisa needs the deck\nTom will fix the login before the release")
        if let blob = note("Call notes with Tom") {
            model.extract(from: blob.range, after: blob)
            await waitWhileBusy()
            log += "\n-- Extract: notice: \(model.aiNotice ?? "-")\n"
            if let start = model.notes.firstIndex(where: { $0.title.hasPrefix("Call notes with Tom") }) {
                for n in model.notes[start...].prefix(4) {
                    log += "  [\(n.type)] \(n.title)" + (n.detailLines.isEmpty ? "" : " / " + n.detailLines.map(\.body).joined(separator: " / ")) + "\n"
                }
            }
        }
        flush(log)

        // Ask
        do throws(AIService.Failure) {
            let context = AIActions.context(for: model.notes, today: Date())
            let answer = try await AIActions.ask("What am I waiting on?", notes: context, earlier: [], ai: model.ai)
            log += "\n-- Ask: \(answer.answer) notes \(answer.notes)\ncontext starts: " + context.split(separator: "\n").prefix(4).joined(separator: " | ") + "\n"
        } catch {
            log += "\n-- Ask FAILED: \(error.message)\n"
        }

        // Without a server: no AI items, no requests
        model.ai.configureForTesting(baseURL: "", model: "")
        let before = AIStub.answeredTasks.count
        if let any = note("Ask Max") { model.tidyUp(any) }
        try? await Task.sleep(for: .milliseconds(500))
        log += "\n-- Removed: configured \(model.ai.isConfigured), backend \(model.engine.backend), requests after removal: \(AIStub.answeredTasks.count - before), notice: \(model.aiNotice ?? "-")\n"
        if let first = model.notes.first {
            log += "gutter items: " + model.gutterMenuItems(at: first.firstLine.range.location).map(\.title).joined(separator: " | ") + "\n"
        }
        log += "requests answered by the stub: " + AIStub.answeredTasks.joined(separator: ", ") + "\n"
        AIStub.install(nil)
        log += "\nNotes after AI:\n" + describe(model)
        return log
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
    static func outsideTask(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    static func type(_ text: String, into tv: NSTextView, window: NSWindow) async -> String {
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
