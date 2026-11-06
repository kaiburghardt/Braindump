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

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        NotesModel.shared.saveNow()
    }
}

struct NoteCommands: Commands {
    let model: NotesModel

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
            Button("Archive Done To-Dos") { model.archiveDone() }
            Button("Refresh Suggestions") { model.reanalyzeAll() }
            Divider()
            Button("Show Notes File in Finder") { model.revealInFinder() }
        }
    }
}
