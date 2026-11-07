import AppKit
import SwiftUI

@main
struct BraindumpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = NotesModel.shared

    var body: some Scene {
        Window("Braindump", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 620, minHeight: 420)
        }
        .defaultSize(width: 1080, height: 720)
        // Always show the window on launch – even if it was closed when the app quit.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { NoteCommands(model: model) }

        Window("History", id: "history") {
            HistoryView(model: model)
                .frame(minWidth: 640, minHeight: 360)
        }
        .defaultSize(width: 880, height: 600)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Test runs only (`-notesPath …`): `-wnAppearance dark|light` forces the look, e.g. for screenshots.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard NotesModel.isTestRun, let look = UserDefaults.standard.string(forKey: "wnAppearance") else { return }
        NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        NotesModel.shared.saveNow()
        NotesModel.shared.captureHistory()
    }
}

struct NoteCommands: Commands {
    let model: NotesModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        // SwiftUI doesn't treat the AppKit text view as focused, so its own Undo/Redo items stay
        // disabled. Send undo:/redo: down the responder chain instead (→ the editor's window).
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                .keyboardShortcut("z")
            Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        // ⌘S out of habit – everything is saved automatically anyway.
        CommandGroup(after: .saveItem) {
            Button("Save") { model.saveNow() }
                .keyboardShortcut("s")
        }
        CommandMenu("Note") {
            Button("To-Do / Done") { model.toggleTodoAtSelection() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Radar On/Off") { model.toggleRadarAtSelection() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Plain Note") { model.clearTypeAtSelection() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
            Divider()
            Button("Merge Selected Lines into One Note") { model.mergeSelection() }
                .keyboardShortcut("j", modifiers: .command)
            Button("Split into Separate Notes") { model.splitSelection() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Tidy Up") { model.tidyUpAtSelection() }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(!model.ai.isConfigured)
            Button("Extract To-Dos") { model.extractAtSelection() }
                .keyboardShortcut("e", modifiers: [.command, .control])
                .disabled(!model.ai.isConfigured)
            Button("Ask Braindump…") { model.askPresented = true }
                .keyboardShortcut("k")
                .disabled(!model.ai.isConfigured)
            Divider()
            Button("Show History") { openWindow(id: "history") }
                .keyboardShortcut("y")
            Divider()
            Button("Archive Done To-Dos") { model.archiveDone() }
            Button("Refresh Suggestions") { model.reanalyzeAll() }
            Divider()
            Button("Show Notes File in Finder") { model.revealInFinder() }
        }
    }
}
