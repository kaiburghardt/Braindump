# Braindump – agent notes

Personal macOS app (SwiftUI + AppKit NSTextView), Swift Package, no Xcode project. Ad-hoc signed, not notarized; shared only as a zip on GitHub releases (no App Store). Formerly "WriteNotes" (the repo folder still has the old name; `NotesModel.migrateFromWriteNotes()` moves old data/defaults once).

## Language: English everywhere

Everything is English: UI text, code (types, variables, methods), comments, commit messages, README/AGENTS.md, and replies to the user, **even when the user writes or dictates in German**. Only user content stays as written: the notes themselves, and data that has to match it (German keywords in `Heuristic`, German lines in `Resources/TrainingLines.json`, German examples in the Foundation Models prompt).

## Build / run
- `./build.sh` → `build/Braindump.app`; `./build.sh --install` → `~/Applications` + launch (quits the running copy first). `Resources/TrainingLines.json` is copied into the bundle.
- Icon: `Tools/make_icon.sh` (draws `Tools/make_icon.swift`, a kawaii brain with sticky notes → `Resources/AppIcon.icns`).
- Do not run downloaded third-party binaries (e.g. llama.cpp releases); that was blocked by policy. The local model is built from Apple frameworks only.
- `CFBundleDevelopmentRegion` is `en`, so system menus are English.
- `README.md` is the GitHub landing page; its images live in `docs/` (`icon.png` = 512 px from `Resources/AppIcon-1024.png`, `screenshot-dark.png` / `screenshot-light.png` at 1800 px wide, shown via `<picture>` by color scheme). Retake screenshots with a test copy (see below) and English demo notes, opened with `open -g -n` so it stays in the background, then `screencapture -l <windowID> -o`. Light mode: pass `-NSRequiresAquaSystemAppearance YES`. The download link points to the latest GitHub release; attach `Braindump.zip` (`ditto -c -k --keepParent build/Braindump.app Braindump.zip`) there, don't commit it.

## Data model
- The editor shows plain text without type markers. On disk: `~/Documents/Braindump/Braindump.json` (`NotesFile`: `format` + `notes` → `[StoredNote]`: type, title, details, spaceBefore, created, lastChecked, archived (archive file only), id), written by hand in a fixed key order (`NotesFile.encoded()`). Render/parse round-trips losslessly.
- A **note** = block of consecutive lines (`NoteParser.blocks`); a blank line ends it; a `#` heading starts its own note. Notes are always rendered with ≥1 blank line between them, because nothing else separates them.
- The **type** (`NoteType`: note, todo, done, radar; JSON `watch` = radar) is data in `NotesModel.records[id]`, not text. IDs stay stable while typing via `assignIDs`: exact title key → fuzzy (`TextSimilarity`) → same slot between matched neighbours → new UUID.
- Typed shortcuts (`[ ] `, `[x] `, `🚧 ` at a line start) are converted into the type and removed (`convertTypedMarkers`, async after the edit, skipped during undo/redo). On a detail line they split it into its own note.
- `pendingNewNote`: after ↩ at the end of a one-line to-do, the empty line two below becomes a to-do once typed on (shown as an empty circle).
- First launch without the JSON imports `Notes.txt` (markers → types, old check dates) and moves the old files to `Old text version/`.
- App-internal state (dismissed suggestions, learned labels) lives in `~/Library/Application Support/Braindump/state.json`.

## Architecture (Sources/Braindump)
- `NotesModel` (@MainActor @Observable singleton): editor text → `notes`, `openTodos`, `doneTodos`, `radarItems`, `suggestions`. Autosave 0.5 s after edits + on resign-active/terminate; polls the JSON mtime every 2 s for external edits; never writes if the load failed. Text edits go through `performEdits`, type changes through `applyTypes`; both are undoable and call `breakUndoCoalescing()` first (otherwise one ⌘Z also reverts the typing before).
- Type styling (done = struck through, radar = semibold title) is applied by the model after each recompute (`restyleAfterTyping`, `restyle`, `restyleAll` → `NoteTextView.applyNoteStyles`), because the storage delegate styles before the model knows the new notes.
- `SuggestionEngine`: Apple Foundation Models if available → else `LineClassifier` → else `Heuristic`. Classifies titles of plain notes. `Heuristic.rule` (explicit `TODO`, `->`, `Idee:` …) always wins. Threshold 0.6.
- `LineClassifier` (actor): Create ML MaxEnt + BERT-embedding classifiers averaged 50/50, labels todo/radar/note, trained on `TrainingLines.json` + the user's own typed notes/learned labels (×3), cached in Application Support, retrained when ≥3 examples changed. Held-out eval 29/30 with rules.
- `LinkPreviewService`: Jira (REST v3, email + API token) and Notion (API, integration token) previews; tokens in Keychain, cache in Application Support. The Jira token only goes to the site from Settings (links on other hosts get no preview); requests use an ephemeral `URLSession` that refuses cross-host redirects. `NoteParser.urlRanges` only links http(s)/mailto.
- `EditorView` / `NoteTextView`: TextKit 1. Styling in `didProcessEditing` + `fixFontAttribute`; restyles ±1 neighbouring line. Do NOT move styling to `willProcessEditing` (the cursor jumps to the line end on every keystroke). Gutter: pool of `NSImageView` icons (one per visible note) + `NoteBar` lines. Click → `NotesModel.gutterClick`: to-do ⇄ done toggles directly; note and radar icons open a small menu (note: To-Do / Radar; radar: Checked Today / Make It a To-Do / Take Off the Radar). Right-click/ctrl-click → `menu(for:)` with all types. Selection pop-up = `SelectionPopupView`, plain AppKit (no nested `NSHostingView` inside the text view).
- `SidebarView`: Radar section, To-Dos, Suggestions.
- Undo/Redo menu items are replaced by buttons that send `undo:`/`redo:` down the responder chain – SwiftUI's own items stay disabled because it doesn't see the AppKit text view as focused.

## Testing without disturbing the installed app
- Copy `build/Braindump.app`, change `CFBundleIdentifier` (e.g. `local.kai.BraindumpTest`), re-sign ad-hoc, `open -n` it with `--args -notesPath /scratch/Braindump.json`. A same-bundle-id copy shares window restoration with the installed app and may launch windowless.
- `-notesPath` puts the app in test mode: no WriteNotes migration, no backups, separate `Application Support/Braindump-Test`. A `Notes.txt` next to the JSON path is imported on first start.
- `-wnSelfTest /path/out` (`SelfTest.swift`, only together with `-notesPath`): import, typing mid-line, icon menus (items performed via the model – real menus would block), checkbox click, typed `[ ] ` + ↩, radar, pop-up, merge/split, classifier, JSON; renders the editor to `/path/out.png`, writes `/path/out.partial.txt` after each section and the full log to `/path/out.txt`. Synthetic key/mouse events are dispatched as plain main-queue blocks (`outsideTask`), not from inside the test's Swift task.
- Do NOT call `endUndoGrouping()` by hand or `window.sendEvent` from inside a Swift task in tests: both corrupted the main-executor checks in the test app (crashes in `swift_task_isMainExecutorImpl`, hangs). Undo can't be tested with synthetic events; test it by hand.
- Build scripts: check `./build.sh`'s exit status, not a `grep` of its output (a matching `grep "error"` "succeeds" and runs stale builds).
- **Never activate/bring a test window to the front**: the user's keystrokes then land in it. Read state via files, screenshots (`screencapture -l <windowID>`) and AX queries instead.
- System Events `click at` performs AX actions, not real mouse events. Key codes are layout-dependent (German QWERTZ: ⌘Z is key 16).
